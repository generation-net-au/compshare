# Satellite-Multihost
This repository is created to provide automated setup for a multihost/multiorg satellite deployment

Its initial setup intentionally uses bash to carry out its role employing hammer commands. 
Its subsequent interation will add ansible, which, per spec, will employ similar hammer commands via commnad/shell ansible modules. 

First script intended to create the initial org/location/hostgroup structure. 
Second script intended to be periodically run, publishing if required, and promoting to the environments requested as required. 
It can be used both for start of patch period publication, and in subsequent weeks for promotion to parameter-specified LCEs. 

Ansible version performs similar function
