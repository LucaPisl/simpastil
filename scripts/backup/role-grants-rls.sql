WITH relation_grants AS (
  SELECT 'database'::text AS object_type, db.datname AS object_schema, NULL::text AS object_name,
         CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END AS grantee,
         acl.privilege_type, acl.is_grantable
  FROM pg_catalog.pg_database AS db
  CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(db.datacl, pg_catalog.acldefault('d', db.datdba))) AS acl
  WHERE db.datname = current_database()
  UNION ALL
  SELECT 'schema', namespace.nspname, NULL::text,
         CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
         acl.privilege_type, acl.is_grantable
  FROM pg_catalog.pg_namespace AS namespace
  CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(namespace.nspacl, pg_catalog.acldefault('n', namespace.nspowner))) AS acl
  WHERE namespace.nspname <> 'information_schema' AND namespace.nspname !~ '^pg_'
  UNION ALL
  SELECT CASE WHEN relation.relkind = 'S' THEN 'sequence' ELSE 'relation' END,
         namespace.nspname, relation.relname,
         CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
         acl.privilege_type, acl.is_grantable
  FROM pg_catalog.pg_class AS relation
  JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(
    relation.relacl,
    pg_catalog.acldefault(CASE WHEN relation.relkind = 'S' THEN 'S'::"char" ELSE 'r'::"char" END, relation.relowner)
  )) AS acl
  WHERE namespace.nspname <> 'information_schema' AND namespace.nspname !~ '^pg_'
    AND relation.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
  UNION ALL
  SELECT 'function', namespace.nspname,
         procedure.proname || '(' || pg_catalog.pg_get_function_identity_arguments(procedure.oid) || ')',
         CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
         acl.privilege_type, acl.is_grantable
  FROM pg_catalog.pg_proc AS procedure
  JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
  CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(procedure.proacl, pg_catalog.acldefault('f', procedure.proowner))) AS acl
  WHERE namespace.nspname <> 'information_schema' AND namespace.nspname !~ '^pg_'
)
SELECT pg_catalog.jsonb_pretty(pg_catalog.jsonb_build_object(
  'formatVersion', 1,
  'database', current_database(),
  'roles', (
    SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'name', role.rolname,
      'canLogin', role.rolcanlogin,
      'isSuperuser', role.rolsuper,
      'canCreateDatabase', role.rolcreatedb,
      'canCreateRole', role.rolcreaterole,
      'inheritsRoles', role.rolinherit,
      'canReplicate', role.rolreplication,
      'bypassesRls', role.rolbypassrls,
      'connectionLimit', role.rolconnlimit,
      'validUntil', role.rolvaliduntil
    ) ORDER BY role.rolname), '[]'::jsonb)
    FROM pg_catalog.pg_roles AS role
    WHERE role.rolname !~ '^pg_'
  ),
  'memberships', (
    SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'role', granted_role.rolname,
      'member', member_role.rolname,
      'adminOption', membership.admin_option,
      'inheritOption', membership.inherit_option,
      'setOption', membership.set_option
    ) ORDER BY granted_role.rolname, member_role.rolname), '[]'::jsonb)
    FROM pg_catalog.pg_auth_members AS membership
    JOIN pg_catalog.pg_roles AS granted_role ON granted_role.oid = membership.roleid
    JOIN pg_catalog.pg_roles AS member_role ON member_role.oid = membership.member
    WHERE granted_role.rolname !~ '^pg_' AND member_role.rolname !~ '^pg_'
  ),
  'grants', (
    SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'objectType', object_type,
      'schema', object_schema,
      'object', object_name,
      'grantee', grantee,
      'privilege', privilege_type,
      'grantable', is_grantable
    ) ORDER BY object_type, object_schema, object_name, grantee, privilege_type), '[]'::jsonb)
    FROM relation_grants
  ),
  'defaultPrivileges', (
    SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'owner', owner_role.rolname,
      'schema', namespace.nspname,
      'objectType', defaults.defaclobjtype,
      'privileges', COALESCE((
        SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'grantee', CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
          'privilege', acl.privilege_type,
          'grantable', acl.is_grantable
        ) ORDER BY acl.grantee, acl.privilege_type)
        FROM LATERAL pg_catalog.aclexplode(defaults.defaclacl) AS acl
      ), '[]'::jsonb)
    ) ORDER BY owner_role.rolname, namespace.nspname, defaults.defaclobjtype), '[]'::jsonb)
    FROM pg_catalog.pg_default_acl AS defaults
    JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = defaults.defaclrole
    LEFT JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = defaults.defaclnamespace
  ),
  'rls', (
    SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'schema', namespace.nspname,
      'table', relation.relname,
      'enabled', relation.relrowsecurity,
      'forced', relation.relforcerowsecurity,
      'policies', COALESCE((
        SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'name', policy.policyname,
          'permissive', policy.permissive,
          'roles', policy.roles,
          'command', policy.cmd,
          'using', policy.qual,
          'withCheck', policy.with_check
        ) ORDER BY policy.policyname)
        FROM pg_catalog.pg_policies AS policy
        WHERE policy.schemaname = namespace.nspname AND policy.tablename = relation.relname
      ), '[]'::jsonb)
    ) ORDER BY namespace.nspname, relation.relname), '[]'::jsonb)
    FROM pg_catalog.pg_class AS relation
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname <> 'information_schema' AND namespace.nspname !~ '^pg_'
      AND relation.relkind IN ('r', 'p')
  )
));
