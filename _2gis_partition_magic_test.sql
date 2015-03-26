CREATE OR REPLACE FUNCTION test_table_before_insert_trigger() RETURNS trigger AS $$
BEGIN
	NEW.id = (NEW.project_id::bit(64) << 47 | NEW.id::bit(64))::bigint;
	RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION initTestPartitions() RETURNS VOID AS $$
BEGIN
	DROP SEQUENCE IF EXISTS "test_table_id_seq1" CASCADE;
	CREATE SEQUENCE "test_table_id_seq1" START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;

	DROP TABLE IF EXISTS test_table CASCADE;
	CREATE TABLE test_table (
	  id BIGINT DEFAULT nextval('test_table_id_seq1'::regclass),
	  project_id INT,
	  value TEXT
	);
	ALTER TABLE ONLY "test_table" ADD CONSTRAINT "pk_test_table" PRIMARY KEY ("id");

	CREATE TRIGGER test_table_before_insert BEFORE INSERT ON test_table FOR EACH ROW EXECUTE PROCEDURE test_table_before_insert_trigger();

	PERFORM _2gis_partition_magic('test_table', 'project_id');
END; $$ LANGUAGE 'plpgsql';

SELECT initTestPartitions();

INSERT INTO test_table(project_id, value) VALUES (1, 'Item 1') RETURNING *;
INSERT INTO test_table(project_id, value) VALUES (2, 'Item 2') RETURNING *;
INSERT INTO test_table(project_id, value) VALUES (3, 'Item 3') RETURNING *;
INSERT INTO test_table(project_id, value) VALUES (4, 'Item 4') RETURNING *;
INSERT INTO test_table(project_id, value)
VALUES
(1, 'Item 5'),
(1, 'Item 6'),
(2, 'Item 7'),
(2, 'Item 8'),
(3, 'Item 9'),
(3, 'Item 10')
RETURNING *;

SELECT COUNT(*) FROM test_table;
SELECT COUNT(*) FROM test_table_1;
SELECT COUNT(*) FROM test_table_2;
SELECT COUNT(*) FROM test_table_3;
SELECT COUNT(*) FROM test_table_4;

SELECT * FROM ONLY test_table;
