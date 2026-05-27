-- Add bookmark_link and excluded_namespaces columns to lrr_config.
-- These were incorrectly added inline to 0005_lrr_config.sql in the working tree;
-- this migration adds them as ALTER TABLE statements for environments that have
-- already applied 0005.

ALTER TABLE lrr_config ADD COLUMN IF NOT EXISTS bookmark_link        VARCHAR(255);
ALTER TABLE lrr_config ADD COLUMN IF NOT EXISTS excluded_namespaces  TEXT NOT NULL DEFAULT '';
