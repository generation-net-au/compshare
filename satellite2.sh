#!/usr/bin/bash

PUBLISH_VERSION=true
PROMOTE_TO_ENV=canary
ORG_NAME=sjl_test

# Get the date in YYYY-MM-DD format.
current_date=`date -I`

id=`hammer organization info --name $ORG_NAME --fields id`
org_id=`echo $id|sed -e 's+^Id: ++'`

for os in rhel8 rhel9 rhel10; do
  cv=cv_$os

  id=`hammer content-view info --organization-id $org_id --name $cv --fields id`
  cv_id=`echo $id|sed -e 's+^Id: ++'`

  # Look for the RPM filter.
  rpm_filter_ids=`hammer --output json content-view filter list --content-view-id $cv_id --types rpm --fields 'filter id'|jq '.[]."Filter ID"'

  # XXX: rpm_filter_ids now holds ALL the RPM filters; we're assuming that
  # there is only one. More than one will cause this script to break.

  # XXX: Need to get the original_packages value for the filter. This is only
  # available through the API, not from hammer.

  # XXX: Once we have that value, check that it's set to true for at least one
  # RPM filter.

  erratum_filter_ids=`hammer --output json content-view filter list --content-view-id $cv_id --types erratum --fields 'filter id'|jq '.[]."Filter ID"'

  # XXX: This may break things if there's more than one erratum filter in the CV,
  # or if there's more than one rule in the erratum filter.
  for i in $erratum_filter_ids; do
    rule_ids=`hammer --output json content-view filter rule list--content-view-filter-id $i|jq '.[]."Rule ID"'`
    for j in $rule_ids; do
      hammer content-view filter rule update --content-view-filter-id $i --id $j --end-date $current_date
    done
  done

  if [ $PUBLISH_VERSION = "true" ]; then
    hammer content-view publish --id $cv_id
  fi

  # Get the highest version ID. This should be the latest version.
  latest_version=`hammer --output json content-view version list --content-view-id $cv_id|jq '.[].Id'|sort -n|tail -1`

  if [ "$PROMOTE_TO_ENV" != "" ]; then
    hammer content-view version promote --content-view-id $cv_id --id $latest_version --to-lifecycle-environment "lce_$PROMOTE_TO_ENV"
  fi
done
