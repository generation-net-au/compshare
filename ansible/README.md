# Satellite Multi-Tenancy Ansible Framework

## Architecture

This framework intentionally separates:
- orchestration logic
- iteration logic
- hammer interaction primitives

## Design Principles

### Playbooks own:
- loops
- orchestration
- sequencing
- hierarchy generation

### Roles own:
- hammer CLI interaction
- reusable CRUD primitives
- idempotent object manipulation

When enabled:
- intended actions are explained in English
- hammer commands are printed
- hammer commands are not executed

## Example Real Execution

ansible-playbook \
  -i inventory.ini \
  bootstrap-multitenancy.yaml

