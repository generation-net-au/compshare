#!/bin/bash

# Parameters that can be changed, or passed in. Hard coded for testing purposes.
ORG=sjl_test
MAIN_LOC=G8NET
OFFERED_OS=("rhel8" "rhel9" "rhel10")
TENANT_LOCS=("miki" "stu" "thorne")
PROMOTION_PATHS=("canary" "dev" "test" "prod")
DEFAULT_CONTENT_VIEW="Default Organization View"

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

# Loop through the operating systems that we want to offer.
for os in ${OFFERED_OS[*]}; do
  # For each operating system, create a hg-OS. LCE at this level is Library.
  # XXX: Check if the hg_OS group already exists in a different organisation, and
  # extend it to our organisation.
  id=`hammer hostgroup info --name hg_$os --organization-id $org_id --fields id`
  if [ -z "$id" ]; then
    hammer hostgroup create --name hg_$os --organization-id $org_id
    id=`hammer hostgroup info --name hg_$os --organization-id $org_id --fields id`
  fi

  parent_name=hg_$os

  hg_os_id=`echo $id|sed -e 's+^Id: ++'`

  # Look for the cv_OS content view and get its ID if it exists. If it doesn't exist,
  # use the default content view.
  id=`hammer content-view info --name cv_$os --organization-id $org_id --fields id`
  if [ -z "$id" ]; then
    id=`hammer content-view info --name "$DEFAULT_CONTENT_VIEW" --organization-id $org_id --fields id`
  fi
  cv_os_id=`echo $id|sed -e 's+^Id: ++'`

  # Now create the sub-locations for each operating system.
  for loc in ${TENANT_LOCS[*]}; do
    id=`hammer hostgroup info --title $parent_name/hg_$loc --organization-id $org_id --fields id`
    # XXX: Check if the hg_LOC group already exists for different organisations and extend it to ours if so.
    if [ -z "$id" ]; then
      # Once again, lifecycle environment is Library at this level.
      hammer hostgroup create --content-view-id $cv_os_id --lifecycle-environment-id $lib_lce_id --location-id $loc_id --name hg_$loc --organization-id $org_id --parent-id $hg_os_id
      id=`hammer hostgroup info --title $parent_name/hg_$loc --organization-id $org_id --fields id`
    fi

    hg_loc_id=`echo $id|sed -e 's+^Id: ++'`
    loc_parent_name=$parent_name/hg_$loc

    # Lastly: promotion paths.
    for prom in ${PROMOTION_PATHS[*]}; do
      # Find the LCE, if it exists.
      id=`hammer lifecycle-environment info --name lce_$prom --organization-id $org_id --fields id`
      if [ -z "$id" ]; then
        # Create, or default? For now: default
        id=`hammer lifecycle-environment info --name Library --organization-id $org_id --fields id`
      fi
      lce_id=`echo $id|sed -e 's+^Id: ++'`
      
      id=`hammer hostgroup info --title $loc_parent_name/hg_$prom --organization-id $org_id --fields id`
      if [ -z "$id" ]; then
        hammer hostgroup create --content-view-id $cv_os_id --lifecycle-environment-id $lce_id --location-id $loc_id --name hg_$prom --organization-id $org_id --parent-id $hg_loc_id
      fi
    done
  done
done

