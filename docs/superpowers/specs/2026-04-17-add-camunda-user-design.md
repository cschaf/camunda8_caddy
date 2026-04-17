# Add Camunda User PowerShell Script — Design

## Overview

A PowerShell script that creates Camunda users via the Keycloak Admin REST API and assigns role-based permissions.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-Username` | string | yes | Login name for the user |
| `-Password` | string | yes | Initial password |
| `-Email` | string | yes | User email address |
| `-FirstName` | string | yes | User's first name |
| `-LastName` | string | yes | User's last name |
| `-Role` | string | yes | Either `NormalUser` or `Admin` |

## Role Definitions

| Role | Assigned Camunda Roles |
|------|----------------------|
| `NormalUser` | Orchestration, Optimize, Web Modeler, Console |
| `Admin` | ManagementIdentity, Orchestration, Optimize, Web Modeler, Web Modeler Admin, Console |

Keycloak and Identity UI access are intentionally excluded for NormalUser.

## Behavior

1. Read `HOST`, `KEYCLOAK_ADMIN_USER`, `KEYCLOAK_ADMIN_PASSWORD` from `.env` (relative to script location)
2. Get admin access token from Keycloak via `POST /auth/admin/realms/master/protocol/openid-connect/token`
3. Create user via `POST /auth/admin/realms/{realm}/users`
4. For each Camunda role:
   - Resolve role UUID via `GET /auth/admin/realms/{realm}/roles/{role-name}`
   - Assign via `POST /auth/admin/realms/{realm}/users/{user-id}/role-mappings/realm`
5. If role assignment fails mid-way, delete the created user (rollback)

## Error Handling

- User already exists → abort with error
- Wrong admin credentials → abort with error
- Keycloak unreachable → abort with error
- Role assignment fails → delete user first, then abort

## File Location

`scripts/add-camunda-user.ps1`
