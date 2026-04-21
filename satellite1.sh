#!/bin/bash

$ORG=sjl_test
$MAIN_LOC=G8NET
$OFFERED_OS=("rhel8" "rhel9" "rhel10")
$TENANT_LOCS=("miki" "stu" "thorne")
$PROMOTION_PATHS=("canary" "dev" "test" "prod")
$DEFAULT_CONTENT_VIEW="Default Organization View"

# Check if the organisation object exists, create it if not

# hammer organization info --name (name)
# returns 0 if exists, non-zero if not.

id=`hammer organization info --name $ORG --fields id`

if [ -z "$id" ]; then
  hammer organization create --name "$ORG"
  id=`hammer organization info --name $ORG --fields id`
fi

org_id=`echo $id|sed -e 's+^Id: ++'`

# Check for the main location, create it if it's not there.
id=`hammer location info $MAIN_LOC --fields id`
if [ -z "$id" ]; then
  hammer location create --name $MAIN_LOC
  id=`hammer location info $MAIN_LOC --fields id`
fi

loc_id=`echo $id|sed -e 's+^Id: ++'`

# Get the Library LCE for the organisation.
id=`hammer lifecycle-environment info --name Library --organization-id $org_id`
lib_lce_id=`echo $i|sed -e 's+^Id: ++'`

for os in ${OFFERED_OS[*]}; do
# For each operating system, create a hg-OS. LCE is Library.
  id=`hammer hostgroup info --name hg_$os --organization-id $org_id --fields id`
  if [ -z "$id" ]; then
    hammer hostgroup create --name hg_$os --organization-id $org_id
    id=`hammer hostgroup info --name hg_$os --organization-id $org_id --fields id`
  fi

  hg_os_id=`echo $id|sed -e 's+^Id: ++'`
  id=`hammer content-view info --name cv_$os --organization-id $org_id --fields id
  if [ -z "$id" ]; then
    id=`hammer content-view info --name $DEFAULT_CONTENT_VIEW --organization-id $org_id --fields id
  fi
  cv_os_id=`echo $id|sed -e 's+^Id: ++'`

  for loc in ${TENANT_LOCS[*]}; do
    id=`hammer hostgroup info --name hg_$loc --organization-id $org_id --parent $hg_os_id`
    if [ -z "$id" ]; then
      # For each location, create a hg-loc underneath the hg-OS. LCE is Library.
      hammer hostgroup create --content-view-id $cv_os_id --lifecycle-environment-id $lib_lce_id --location-id $loc_id --name hg_$loc --organization-id $org_id --parent $hg_os_id
      id=`hammer hostgroup info --name hg_$loc --organization-id $org_id --parent $hg_os_id`
    fi

    hg_loc_id=`echo $id|sed -e 's+^Id: ++'`

    for prom in ${PROMOTION_PATHS[*]}; do
      # Find the LCE, if it exists.
      id=`hammer lifecycle-environment info --name lce_$prom --organization-id $org_id`
      if [ -z "$id" ]; then
        # Create, or default? For now: default
        id=`hammer lifecycle-environment info --name Library --organization-id $org_id`
      fi
      lce_id=`echo $i|sed -e 's+^Id: ++'`
      hammer hostgroup create --content-view-id $cv_os_id --lifecycle-environment-id $lce_id --location-id $loc_id --name hg_$prom --organization-id $org_id --parent $hg_loc_id
    done
  done
done

