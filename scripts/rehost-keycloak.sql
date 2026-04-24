\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE restore_client_urls (
  client_id text PRIMARY KEY,
  root_url text,
  base_url text,
  admin_url text
) ON COMMIT DROP;

INSERT INTO restore_client_urls (client_id, root_url, base_url, admin_url) VALUES
  ('console', 'https://console.' || :'host', '/', 'https://console.' || :'host'),
  ('orchestration', 'https://orchestration.' || :'host', '/', 'https://orchestration.' || :'host'),
  ('optimize', 'https://optimize.' || :'host', '/', 'https://optimize.' || :'host'),
  ('web-modeler', 'https://webmodeler.' || :'host', '/', 'https://webmodeler.' || :'host'),
  ('camunda-identity', 'https://identity.' || :'host', '/', 'https://identity.' || :'host');

CREATE TEMP TABLE restore_redirect_uris (
  client_id text,
  value text
) ON COMMIT DROP;

INSERT INTO restore_redirect_uris (client_id, value) VALUES
  ('console', '/'),
  ('console', 'http://' || :'host' || ':8087/'),
  ('orchestration', '/sso-callback'),
  ('orchestration', 'http://' || :'host' || ':8088/sso-callback'),
  ('optimize', '/api/authentication/callback'),
  ('optimize', 'http://' || :'host' || ':8083/api/authentication/callback'),
  ('web-modeler', '/login-callback'),
  ('web-modeler', 'http://' || :'host' || ':8070/login-callback'),
  ('camunda-identity', '/auth/login-callback'),
  ('camunda-identity', 'https://identity.' || :'host' || '/auth/login-callback'),
  ('camunda-identity', 'http://' || :'host' || ':8084/auth/login-callback');

CREATE TEMP TABLE restore_web_origins (
  client_id text,
  value text
) ON COMMIT DROP;

INSERT INTO restore_web_origins (client_id, value) VALUES
  ('console', 'https://console.' || :'host'),
  ('orchestration', 'https://orchestration.' || :'host'),
  ('optimize', 'https://optimize.' || :'host'),
  ('web-modeler', 'https://webmodeler.' || :'host'),
  ('camunda-identity', 'https://identity.' || :'host');

CREATE TEMP TABLE restore_client_secrets (
  client_id text PRIMARY KEY,
  secret text
) ON COMMIT DROP;

INSERT INTO restore_client_secrets (client_id, secret) VALUES
  ('connectors', :'connectors_secret'),
  ('console', :'console_secret'),
  ('orchestration', :'orchestration_secret'),
  ('optimize', :'optimize_secret'),
  ('camunda-identity', :'identity_secret');

DO $$
DECLARE
  client_row record;
  client_pk text;
  url_row record;
  secret_row record;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = current_schema() AND table_name = 'client'
  ) THEN
    RAISE EXCEPTION 'Keycloak table "client" not found; cannot rehost clients';
  END IF;

  FOR url_row IN SELECT * FROM restore_client_urls LOOP
    SELECT id INTO client_pk FROM client WHERE client_id = url_row.client_id LIMIT 1;
    IF client_pk IS NULL THEN
      RAISE NOTICE 'Keycloak client "%" not found; skipping URL rehost', url_row.client_id;
      CONTINUE;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'client' AND column_name = 'root_url') THEN
      UPDATE client SET root_url = url_row.root_url WHERE id = client_pk;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'client' AND column_name = 'base_url') THEN
      UPDATE client SET base_url = url_row.base_url WHERE id = client_pk;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'client' AND column_name = 'admin_url') THEN
      UPDATE client SET admin_url = url_row.admin_url WHERE id = client_pk;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'client' AND column_name = 'management_url') THEN
      UPDATE client SET management_url = url_row.admin_url WHERE id = client_pk;
    END IF;

    IF EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = current_schema() AND table_name = 'redirect_uris'
    ) THEN
      DELETE FROM redirect_uris WHERE client_id = client_pk;
      INSERT INTO redirect_uris (client_id, value)
      SELECT client_pk, value FROM restore_redirect_uris WHERE client_id = url_row.client_id;
    ELSE
      RAISE NOTICE 'Keycloak table "redirect_uris" not found; skipping redirect URI rehost';
    END IF;

    IF EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = current_schema() AND table_name = 'web_origins'
    ) THEN
      DELETE FROM web_origins WHERE client_id = client_pk;
      INSERT INTO web_origins (client_id, value)
      SELECT client_pk, value FROM restore_web_origins WHERE client_id = url_row.client_id;
    ELSE
      RAISE NOTICE 'Keycloak table "web_origins" not found; skipping web origin rehost';
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'client' AND column_name = 'secret') THEN
    FOR secret_row IN SELECT * FROM restore_client_secrets LOOP
      IF secret_row.secret IS NULL OR secret_row.secret = '' THEN
        RAISE NOTICE 'No local secret supplied for Keycloak client "%"; leaving restored secret unchanged', secret_row.client_id;
      ELSE
        UPDATE client SET secret = secret_row.secret WHERE client_id = secret_row.client_id;
      END IF;
    END LOOP;
  ELSE
    RAISE NOTICE 'Keycloak client.secret column not found; skipping client secret rehost';
  END IF;
END $$;

COMMIT;
