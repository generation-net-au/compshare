#!/bin/bash

# Pre-create content view and filters; publish; and pre create all lifecycle environment paths.

# Parameters that can be changed, or passed in. Hard coded for testing purposes.
ORG=sjl_test
MAIN_LOC=G8NET
OFFERED_OS=("rhel8" "rhel9" "rhel10")
TENANT_LOCS=("miki" "stu" "thorne")
PROMOTION_PATHS=("canary" "dev" "test" "prod")
DEFAULT_CONTENT_VIEW="Default Organization View"

# Check if the organisation object exists, create it if not
id=`hammer organization info --name $ORG --fields id`

# Look at a host group. Check if it's a member of the organisation that we want
# it to be part of. If yes - do nothing. If no - add it, without clobbering
# any existing organisation memberships.
#
# Parameters:
#   $1 - the title of the hostgroup. (Not the name - the fully qualified title.)
#   $2 - the organisation ID that it should belong to.
function update_hostgroup () {
  local x
  local have_match
  local new_org_ids
  local i

  x=`hammer --output json hostgroup info --title $1|jq '.Organizations[].Id'`
  have_match=false
  new_org_ids="$2"
  for i in $x; do
    if [ $i -eq $2 ]; then
      have_match=true
      return
    else
      new_org_ids="$i,$new_org_ids"
    fi
  done

  # Note that we've been building up $new_org_ids by pre-pending membership
  # IDs, followed by a comma, starting with just the organisation that the
  # host group should be a member of. Thus, $new_org_ids will be exactly the
  # list of organisations the group should be in.
  if [ $have_match = "false" ]; then
    hammer hostgroup update --title $1 --organization-ids "$new_org_ids"
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
  local x
  local id

  x=`hammer lifecycle-environment info --fields id --name $1 --organization-id $2`
  if [ -z "$x" ]; then
    # It doesn't exist. Create it.
    hammer lifecycle-environment create --name $1 --organization-id $2 --prior-id $3
    x=`hammer lifecycle-environment info --fields id --name $1 --organization-id $2`
  fi

  id=`echo $x|sed -e 's+Id: ++'`
  echo $id
}

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
for i in canary test prod dev; do
  prev_id=`create_lifecycle_env lce_$i $org_id $lib_lce_id`
  declare "${i}_lce_id"=$prev_id
done

# Debugging. Remove. XXX
echo $canary_lce_id $test_lce_id $prod_lce_id $dev_lce_id

# Now that we have the environment paths: look for and validate the content views.

# Loop through the operating systems that we want to offer.
for os in ${OFFERED_OS[*]}; do
  # Check whether a content view for the OS exists. If it doesn't, create it, and apply the
  # desired filters.
  id=`hammer content-view info --name cv_$os --organization-id $org_id --fields id`
  if [ -z "$id" ]; then
    # We don't assign repositories here. Assigning repositories requires that the organisation
    # have a valid subscription manifest applied. Doing that via this script is... complicated.
    hammer content-view create --name cv_$os --organization-id $org_id --auto-publish false
    id=`hammer content-view info --name cv_$os --organization-id $org_id --fields id`
    cv_os_id=`echo $id|sed -e 's+^Id: ++'`

    # Create the filters. There are no repositories, but we create the filters anyway so that
    # the framework is in place.

    # First, the RPM filter.
    hammer content-view filter create --content-view-id $cv_os_id --inclusion true --name filter_noerrata --organization-id $org_id --original-packages true --type rpm

    # Second, the errata filter.
    hammer content-view filter create --content-view-id $cv_os_id --inclusion true --name filter_periodically_updates --organization-id $org_id --type erratum
    cvf_id=`hammer content-view filter --content-view-id $cv_os_id --fields id --name filter_periodically_updates --organization-id $org_id|sed -e 's+^Id: ++'`
    # XXX: Defaults to today. Is this correct?
    hammer content-view filter rule create --content-view-filter-id $cvf_id --content-view-id $cv_os_id --end-date `date -I` --organization-id $org_id --types enhancement,bugfix,security

    # XXX: Do we need to publish a version before we proceed?
  fi
  cv_os_id=`echo $id|sed -e 's+^Id: ++'`

  # For each operating system, create a hg-OS. LCE at this level is Library.
  # The hg_OS group might already exist in a different organisation, in which
  # case, extend it to our organisation.
  id=`hammer hostgroup info --title hg_$os --fields id`
  if [ -z "$id" ]; then
    hammer hostgroup create --name hg_$os --organization-id $org_id
    id=`hammer hostgroup info --title hg_$os --fields id`
  else
    update_hostgroup hg_$os $org_id
  fi

  parent_name=hg_$os

  hg_os_id=`echo $id|sed -e 's+^Id: ++'`

  # Now create the sub-locations for each operating system.
  for loc in ${TENANT_LOCS[*]}; do
    id=`hammer hostgroup info --title $parent_name/hg_$loc --fields id`
    if [ -z "$id" ]; then
      # Once again, lifecycle environment is Library at this level.
      hammer hostgroup create --content-view-id $cv_os_id --lifecycle-environment-id $lib_lce_id --location-id $loc_id --name hg_$loc --organization-id $org_id --parent-id $hg_os_id
      id=`hammer hostgroup info --title $parent_name/hg_$loc --fields id`
    else
      update_hostgroup $parent_name/hg_$loc $org_id
    fi

    hg_loc_id=`echo $id|sed -e 's+^Id: ++'`
    loc_parent_name=$parent_name/hg_$loc

    # Lastly: promotion paths.
    for prom in ${PROMOTION_PATHS[*]}; do
      lce_varname=${prom}_lce_id
      # Find the LCE, if it exists.
      # This is a bit of bash magic. ${!foo} means "look at the variable foo. Expand it. Look at the variable that it refers to and return its value."
      lce_id=${!lce_varname}
      if [ -z "$lce_id" ]; then
        echo "Couldn't find the LCE ID for $prom - we shouldn't be here.."
        # Create, or default? For now: default
        id=`hammer lifecycle-environment info --name Library --organization-id $org_id --fields id`
        lce_id=`echo $id|sed -e 's+^Id: ++'`
      fi
      
      id=`hammer hostgroup info --title $loc_parent_name/hg_$prom --fields id`
      if [ -z "$id" ]; then
        hammer hostgroup create --content-view-id $cv_os_id --lifecycle-environment-id $lce_id --location-id $loc_id --name hg_$prom --organization-id $org_id --parent-id $hg_loc_id
      else
        update_hostgroup $loc_parent_name/hg_$prom $org_id
      fi
    done
  done
done
