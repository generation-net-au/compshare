#!/bin/bash

# Pre-create content view and filters; publish; and pre create all lifecycle environment paths.

# Parameters that can be changed, or passed in. Hard coded for testing purposes.
ORG=sjl_t10
MAIN_LOC=G8NET
OFFERED_OS=("rhel8" "rhel9" "rhel10")
TENANT_LOCS=("loc1" "loc2" "loc3")
PROMOTION_PATHS=("canary" "test" "prod" "dev")

# Look at a host group. Check if it's a member of the organisation that we want
# it to be part of. If yes - do nothing. If no - add it, without clobbering
# any existing organisation memberships.
#
# Parameters:
#   $1 - the title of the hostgroup. (Not the name - the fully qualified title.)
#   $2 - the organisation ID that it should belong to.
#   $3 - the location ID (for $MAIN_LOC).
function update_hostgroup () {
  local current_hg_associated_org_list
  local have_match
  local new_org_ids
  local org
  local current_hg_associated_loc_list
  local new_loc_ids

  current_hg_associated_org_list=`hammer --output json hostgroup info --title $1|jq '.Organizations[].Id'`
  have_match=false
  # Initialise the list with the org we need to update the host group into
  new_org_ids="$2"
  for org in $current_hg_associated_org_list; do
    if [ $org -eq $2 ]; then
      have_match=true
      # The host group is already in the organisation; nothing to do - break out of the function.
      return
    else
      new_org_ids="$org,$new_org_ids"
    fi
  done

  # We've validated that the hostgroup isn't in the organisation. Check its
  # list of locations.
  current_hg_associated_loc_list=`hammer --output json hostgroup info --title $1|jq '.Locations[].Id'`
  new_loc_ids="$3"
  for loc in $current_hg_associated_loc_list; do
    # Only add the location to the list if it isn't the 'new' location. If it is,
    # do nothing (as we already initialised the list with it).
    if [ $loc -ne $3 ]; then
      new_loc_ids="$loc,new_loc_ids"
    fi
  done

  # Note that we've been building up $new_org_ids by pre-pending organisation
  # IDs, followed by a comma, starting with just the organisation that the
  # host group should be a member of. Thus, $new_org_ids will be exactly the
  # list of organisations the group should be in.
  if [ $have_match = "false" ]; then
    hammer hostgroup update --title $1 --organization-ids "$new_org_ids" --location-ids $new_loc_ids
  else
    echo We should never get here.
  fi
}

# Look for and create a lifecycle environment if it doesn't already exist.
# Return the ID.
#
# Parameters:
#   $1 - name of the new environment
#   $2 - organization ID to create it in
#   $3 - the prior environment ID (either the Library ID, or the tail end of the chain.)
function create_lifecycle_env () {
  local lce_id
  local id

  lce_id=`hammer lifecycle-environment info --fields id --name $1 --organization-id $2`
  if [ -z "$lce_id" ]; then
    # It doesn't exist. Create it.
    hammer lifecycle-environment create --name $1 --organization-id $2 --prior-id $3 > /dev/null 2>&1
    lce_id=`hammer lifecycle-environment info --fields id --name $1 --organization-id $2`
  fi

  id=`echo $lce_id|sed -e 's+Id: ++'`
  echo $id
}

# Check if the organisation object exists, create it if not
id=`hammer organization info --name $ORG --fields id`

if [ -z "$id" ]; then
  hammer organization create --name "$ORG"
  id=`hammer organization info --name $ORG --fields id`
fi

# Grab the organisation ID; it's significantly easier to work with that than the string name.
org_id=`echo $id|sed -e 's+^Id: ++'`

# Check for the main location, create it if it's not there.
# Note: The check-create-check-get-ID pattern is very common.
# To do: separate that pattern into a function for neatness.
id=`hammer location info --name $MAIN_LOC --fields id`
if [ -z "$id" ]; then
  hammer location create --name $MAIN_LOC
  id=`hammer location info --name $MAIN_LOC --fields id`
fi

loc_id=`echo $id|sed -e 's+^Id: ++'`

# Get the Library LCE for the organisation.
id=`hammer lifecycle-environment info --name Library --organization-id $org_id --fields id`
lib_lce_id=`echo $id|sed -e 's+^Id: ++'`

# Check for the environment path: we want two streams. Stream one is Library -> lce_infra.
# Stream two is Library -> lce_canary -> lce_test -> lce_prod -> lce_dev.
# Note that the LCE name must be unique within an organisation, so if one of those
# already exists, we assume that it's in the right position in the stream.

# lce_infra is its own thing.
infra_lce_id=`create_lifecycle_env lce_infra $org_id $lib_lce_id`

prev_id=$lib_lce_id
all_lce_ids="$lib_lce_id,$infra_lce_id"
lce_path_ids=()
for i in ${PROMOTION_PATHS[*]}; do
  prev_id=`create_lifecycle_env lce_$i $org_id $prev_id`
  lce_path_ids+=( $prev_id )
  all_lce_ids="$all_lce_ids,$prev_id"
done

# Now that we have the environment paths: look for and validate the content views.


# Parameters:
#   $1 - the operating system (rhel8, rhel9, rhel94, etc.)
#   $2 - the organisation ID
#   $3 - the architecture (defaults to x86_64 if not specified)
function build_repo_list () {
  # Munge the OS into the form used for naming repositories. Note:
  # this pattern doesn't work for RHEL 7 or earlier.
  local os_ver=`echo $1|sed -e 's+^rhel++'`
  local org_id=$2
  local arch=$3

  if [ "$arch" = "" ]; then
    arch=x86_64
  fi

  # We're looking specifically for three repositories:
  # Content labels:
  #   rhel-X-for-ARCH-baseos-rpms
  #   rhel-X-for-ARCH-appstream-rpms
  #   satellite-client-6-for-rhel-X-ARCH-rpms
  # or names:
  #   Red Hat Enterprise Linux X for ARCH - BaseOS RPMs X
  #   Red Hat Enterprise Linux X for ARCH - AppStream RPMs X
  #   Red Hat Satellite Client 6 for RHEL X ARCH RPMs
  #
  # Hammer only lets us search by name, not content label (a pity), so that's what we're doing.
  local os_name="Red Hat Enterprise Linux ${os_ver} for ${arch}"
  local product_name="Red Hat Enterprise Linux for ${arch}"

  local baseos_rpms_repo=`hammer repository info --name "${os_name} - BaseOS RPMs ${os_ver}" --organization-id $org_id --fields id --product "$product_name"`
  if [ -z "$baseos_rpms_repo" ]; then
    # If the base OS RPMs aren't available, let's assume that the others are unavailable
    # as well.
    return
  fi
  local appstream_rpms_repo=`hammer repository info --name "${os_name} - AppStream RPMs ${os_ver}" --organization-id $org_id --fields id --product "$product_name"`
  if [ -z "$appstream_rpms_repo" ]; then
    # This shouldn't happen, quietly abort.
    return
  fi

  # Convert the text string hammer outputs into a comma separated list of IDs.
  local repository_ids="`echo $baseos_rpms_repo|sed -e 's+^Id: ++'`,`echo $appstream_rpms_repo|sed -e 's+^Id: ++'`"
  local satellite_rpms_repo=`hammer repository info --name "Red Hat Satellite Client 6 for RHEL ${os_ver} ${arch} RPMs" --organization-id $org_id --fields id --product "$product_name"`
  if [ -z "$satellite_rpms_repo" ]; then
    echo $repository_ids
    return
  fi
  local sat_repo_id=`echo $satellite_rpms_repo|sed -e 's+^Id: ++'`
  echo ${repository_ids},${sat_repo_id}
}

# Loop through the operating systems that we want to offer.
for tier1_hg_os in ${OFFERED_OS[*]}; do
  # Check whether a content view for the OS exists. If it doesn't, create it, and apply the
  # desired filters.
  cv_id_str=`hammer content-view info --name cv_$tier1_hg_os --organization-id $org_id --fields id`
  if [ -z "$cv_id_str" ]; then
    # Attempt to add the repositories in. Note that this requires a subscription
    # manifest. If we created the organisation, there won't be a manifest, so there
    # won't be any repositories.
    repo_list=`build_repo_list $tier1_hg_os $org_id x86_64`
    if [ -z "$repo_list" ]; then
      repo_param=""
    else
      repo_param="--repository-ids ${repo_list}"
    fi
    hammer content-view create --name cv_$tier1_hg_os --organization-id $org_id --auto-publish false $repo_param
    cv_id_str=`hammer content-view info --name cv_$tier1_hg_os --organization-id $org_id --fields id`
    cv_os_id=`echo $cv_id_str|sed -e 's+^Id: ++'`

    # Create the filters. There might be no repositories, but we create the filters anyway so that
    # the framework is in place.

    # First, the RPM filter.
    hammer content-view filter create --content-view-id $cv_os_id --inclusion true --name filter_noerrata --organization-id $org_id --original-packages true --type rpm

    # Second, the errata filter and rule.
    hammer content-view filter create --content-view-id $cv_os_id --inclusion true --name filter_periodically_updates --organization-id $org_id --type erratum
    cvf_id_str=`hammer content-view filter info --content-view-id $cv_os_id --fields 'filter id' --name filter_periodically_updates --organization-id $org_id`
    cvf_id=`echo $cvf_id_str|sed -e 's+^Filter ID: ++'`
    # XXX: Defaults to today. Is this correct?
    hammer content-view filter rule create --content-view-filter-id $cvf_id --content-view-id $cv_os_id --end-date `date -I` --organization-id $org_id --types enhancement,bugfix,security

    # XXX: Do we need to publish a version before we proceed? - yes.
    hammer content-view publish --id $cv_os_id --organization-id $org_id --lifecycle-environments $all_lce_ids

    # And now forcibly promote it to all the LCEs, because we can't associate an LCE if it doesn't have the CV version.
    for lce_id in ${lce_path_ids[*]}; do
      hammer content-view version promote --content-view-id $cv_os_id --from-lifecycle-environment-id $lib_lce_id --to-lifecycle-environment-id $lce_id --organization-id $org_id
    done
  fi
  cv_os_id=`echo $cv_id_str|sed -e 's+^Id: ++'`

  # For each operating system, create a hg-OS. LCE at this level is Library.
  # The hg_OS group might already exist in a different organisation, in which
  # case, extend it to our organisation.
  str_hg_id=`hammer hostgroup info --title hg_$tier1_hg_os --fields id`
  if [ -z "$str_hg_id" ]; then
    hammer hostgroup create --name hg_$tier1_hg_os --organization-id $org_id --lifecycle-environment-id $lib_lce_id --content-view-id $cv_os_id --location-id $loc_id
    str_hg_id=`hammer hostgroup info --title hg_$tier1_hg_os --fields id`
  else
    update_hostgroup hg_$tier1_hg_os $org_id $loc_id
  fi

  parent_name=hg_$tier1_hg_os

  # Derive the ID number from the string hammer returned
  hg_os_id=`echo $str_hg_id|sed -e 's+^Id: ++'`

  # Now create the nested location hostgroups for each operating system.
  for tier2_hg_loc in ${TENANT_LOCS[*]}; do
    id=`hammer hostgroup info --title $parent_name/hg_$tier2_hg_loc --fields id`
    if [ -z "$id" ]; then
      # Once again, lifecycle environment is Library at this level.
      # We don't specify a content view, so it will inherit it from the higher level.
      hammer hostgroup create --name hg_$tier2_hg_loc --lifecycle-environment-id $lib_lce_id --location-id $loc_id --organization-id $org_id --parent-id $hg_os_id
      id=`hammer hostgroup info --title $parent_name/hg_$tier2_hg_loc --fields id`
    else
      update_hostgroup $parent_name/hg_$tier2_hg_loc $org_id $loc_id
    fi

    hg_loc_id=`echo $id|sed -e 's+^Id: ++'`
    loc_parent_name=$parent_name/hg_$tier2_hg_loc

    # Lastly: promotion paths. Tier 3.
    for count in ${!PROMOTION_PATHS[@]}; do
      tier3_hg_name=hg_${PROMOTION_PATHS[$count]}
      # Find the LCE, if it exists.
      lce_id=${lce_path_ids[$count]}
      if [ -z "$lce_id" ]; then
        echo "Couldn't find the LCE ID for ${PROMOTION_PATHS[$count]} - we shouldn't be here.."
        # Create, or default? For now: default
        lce_id=$lib_lce_id
      fi
      
      id=`hammer hostgroup info --title $loc_parent_name/$tier3_hg_name --fields id`
      if [ -z "$id" ]; then
        # We don't specify a content view, so it will inherit it from the higher level.
        hammer hostgroup create --name $tier3_hg_name --lifecycle-environment-id $lce_id --location-id $loc_id --organization-id $org_id --parent-id $hg_loc_id
      else
        update_hostgroup $loc_parent_name/$tier3_hg_name $org_id $loc_id
      fi
      # Look for and, if necessary, Create an activation key:
      # OS, location, environment (lce_X) and content view (cv_rhelX)
      {
        hammer activation-key info --name "ak_${tier1_hg_os}_${tier2_hg_loc}_${PROMOTION_PATHS[$count]}" --organization-id ${org_id}
      } || {
        hammer activation-key create --name ak_${tier1_hg_os}_${tier2_hg_loc}_${PROMOTION_PATHS[$count]} --lifecycle-environment-id $lce_id --content-view-id ${cv_os_id} --organization-id ${org_id} --unlimited-hosts
      }
    done
  done
done
