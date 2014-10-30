CREATE OR REPLACE FUNCTION _2gis_partition_magic_before_insert_trigger() RETURNS trigger AS $$
DECLARE
	hasMeta boolean;
	meta RECORD;
	partition_id integer;
	itable text;
	partitionRes boolean;
BEGIN
	hasMeta := false;
	FOR meta IN SELECT * FROM _2gis_partition_magic_meta m WHERE m.table_name = TG_TABLE_NAME
	LOOP
		hasMeta := true;
	END LOOP;

	IF hasMeta THEN
		EXECUTE format('SELECT ($1).%I', meta.action_field) USING NEW INTO partition_id;
		itable := meta.partition_table_prefix || partition_id::text;

		IF ( NOT EXISTS ( SELECT 1 FROM pg_tables t WHERE t.schemaname = meta.schema_name AND t.tablename = itable ) ) THEN
			partitionRes := _2gis_partition_magic(meta.parent_table_name, meta.action_field, partition_id, meta.schema_name, meta.partition_table_prefix, FALSE);
		END IF;

		EXECUTE 'INSERT INTO ' || itable || ' VALUES (($1).*) ' USING NEW;
	END IF;

	RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _2gis_partition_magic_after_insert_trigger() RETURNS trigger AS $$
DECLARE
	hasMeta boolean;
	meta RECORD;
	itable text;
BEGIN
	hasMeta := false;
	FOR meta IN SELECT * FROM _2gis_partition_magic_meta m WHERE m.table_name = TG_TABLE_NAME
	LOOP
		hasMeta := true;
	END LOOP;

	IF hasMeta THEN
		EXECUTE 'DELETE FROM ONLY ' || meta.parent_table_name || ' WHERE id = ' || NEW.id || ';';
	END IF;

	RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _2gis_partition_magic(parent_table text, action_field text, partition_idx integer = NULL, schema_name text = NULL, partition_table_prefix text = NULL, is_debug boolean = FALSE) RETURNS boolean AS $$
DECLARE
    itable varchar(255);
    logtable varchar(255);
    idx1_name varchar(255);
    idx2_name varchar(255);
    s1 varchar(255);
    s2 varchar(255);
    idx1_def text;
    idx2_def text;
    tbl RECORD;
    idx1 RECORD;
    idx2 RECORD;
    rule1 RECORD;
    rule2 RECORD;
    trig1 RECORD;
    trig2 RECORD;
    res boolean;
BEGIN
	res := TRUE;

	IF(schema_name IS NULL) THEN
		schema_name := current_schema(); --'public'
	END IF;

	IF(partition_table_prefix IS NULL) THEN
		partition_table_prefix := parent_table || '_';
	END IF;

	IF ( NOT EXISTS ( SELECT 1 FROM pg_tables t WHERE t.schemaname = schema_name AND t.tablename = '_2gis_partition_magic_meta' ) ) THEN
		IF(is_debug) THEN RAISE INFO '----- [Creating META table "%"] -----', '_2gis_partition_magic_meta'; END IF;
		EXECUTE 'CREATE TABLE _2gis_partition_magic_meta (id integer, table_name character varying(255), action_field character varying(255), partition_id integer, schema_name character varying(255), partition_table_prefix character varying(255), parent_table_name character varying(255), created_at TIMESTAMP DEFAULT NOW());';
		EXECUTE 'CREATE INDEX table_name_idx ON _2gis_partition_magic_meta (table_name);';
		EXECUTE 'CREATE INDEX partition_id_idx ON _2gis_partition_magic_meta (partition_id);';
		EXECUTE 'CREATE INDEX parent_table_name_idx ON _2gis_partition_magic_meta (parent_table_name);';
	END IF;

	IF ( NOT EXISTS ( SELECT 1 FROM _2gis_partition_magic_meta m WHERE m.table_name = parent_table ) ) THEN
		IF(is_debug) THEN RAISE INFO '----- [Creating META for table "%.%"] -----', schema_name, parent_table; END IF;
		EXECUTE 'INSERT INTO _2gis_partition_magic_meta (table_name, action_field, partition_id, schema_name, partition_table_prefix, parent_table_name) VALUES (''' || parent_table || ''', ''' || action_field || ''', NULL, ''' || schema_name || ''', ''' || partition_table_prefix || ''', ''' || parent_table || ''');';
	END IF;

	IF ( NOT EXISTS ( SELECT g.tgfoid::regclass::text, pg_get_functiondef(p.oid) as procdef, prosrc, pg_get_triggerdef(g.oid) as tgdef, g.tgname
	FROM pg_trigger g
	LEFT JOIN pg_proc p ON p.oid = g.tgfoid
	WHERE g.tgrelid::regclass::text = parent_table AND g.tgname = '_2gis_partition_magic_before_insert_' || parent_table AND g.tgenabled != 'D' AND NOT g.tgisinternal ) )
	THEN
		IF(is_debug) THEN RAISE INFO '----- [Creating before insert trigger on parent_table "%.%"] -----', schema_name, parent_table; END IF;
		EXECUTE 'CREATE TRIGGER _2gis_partition_magic_before_insert_' || parent_table || ' BEFORE INSERT ON ' || parent_table || ' FOR EACH ROW EXECUTE PROCEDURE _2gis_partition_magic_before_insert_trigger();';
		IF(is_debug) THEN RAISE INFO '----- [Creating after insert trigger on parent_table "%.%"] -----', schema_name, parent_table; END IF;
		EXECUTE 'CREATE TRIGGER _2gis_partition_magic_after_insert_' || parent_table || ' AFTER INSERT ON ' || parent_table || ' FOR EACH ROW EXECUTE PROCEDURE _2gis_partition_magic_after_insert_trigger();';
	END IF;

	IF(partition_idx IS NULL) THEN
		IF(is_debug) THEN RAISE INFO '----- [Detecting partitions...] -----'; END IF;
		FOR tbl IN SELECT t.tablename, substring(t.tablename from '\_(\d+)$')::integer AS part_index FROM pg_tables t WHERE t.schemaname = schema_name AND t.tablename ~* ('^' || partition_table_prefix || '\d+') ORDER BY part_index ASC
		LOOP
			partition_idx := replace(tbl.tablename, partition_table_prefix, '')::integer;
			IF(is_debug) THEN RAISE INFO '----- [Found partition #%, table: "%.%"] -----', partition_idx, schema_name, tbl.tablename; END IF;
			res := res AND _2gis_partition_magic(parent_table, action_field, partition_idx, schema_name, partition_table_prefix, is_debug);
		END LOOP;

		RETURN res;
	END IF;

	IF(partition_idx < 0) THEN
		partition_idx := NULL;
		itable := partition_table_prefix;
	ELSE
		itable := partition_table_prefix || partition_idx;
	END IF;

	IF(is_debug) THEN RAISE INFO '----- [Working with table "%.%"] -----', schema_name, itable; END IF;

	IF ( NOT EXISTS ( SELECT 1 FROM pg_tables t WHERE t.schemaname = schema_name AND t.tablename = itable ) ) THEN
		IF(is_debug) THEN RAISE INFO 'Creating partition "%.%" for table "%.%"...', schema_name, itable, schema_name, parent_table; END IF;
		EXECUTE 'CREATE TABLE ' || itable || ' (CONSTRAINT ' || itable || '_' || action_field || '_check CHECK (' || action_field || ' = ' || partition_idx || ')) INHERITS (' || parent_table ||');';
		-- IF(is_debug) THEN RAISE INFO 'Creating rules on table...'; END IF;
		-- EXECUTE 'CREATE RULE ' || itable || '_insert AS ON INSERT TO ' || parent_table || ' WHERE NEW.' || action_field || ' = ' || partition_idx || ' DO INSTEAD INSERT INTO ' || itable || ' VALUES (NEW.*) RETURNING ' || itable || '.*;';
		IF(is_debug) THEN RAISE INFO 'Creating meta info...'; END IF;
		EXECUTE 'INSERT INTO _2gis_partition_magic_meta (table_name, action_field, partition_id, schema_name, partition_table_prefix, parent_table_name) VALUES (''' || itable || ''', ''' || action_field || ''', ' || partition_idx || ', ''' || schema_name || ''', ''' || partition_table_prefix || ''', ''' || parent_table || ''');';
	END IF;

	IF(is_debug) THEN RAISE INFO 'Checking indexes...'; END IF;
	FOR idx1 IN SELECT t.indexname, t.indexdef FROM pg_indexes t WHERE t.schemaname = schema_name AND t.tablename = parent_table
	LOOP
		idx1_name := idx1.indexname;
		idx2_name := regexp_replace(idx1_name, '^(' || parent_table || '_)', itable || '_');
		IF (idx2_name = idx1_name) THEN
			idx2_name := regexp_replace(idx1_name, '(\w+_|)(' || parent_table || ')(_\w+|)', '\1' || itable || '\3');
		END IF;

		SELECT t.indexname, t.indexdef INTO idx2 FROM pg_indexes t WHERE t.schemaname = schema_name AND t.tablename = itable AND t.indexname = idx2_name;

		idx1_def := idx1.indexdef;
		idx1_def := regexp_replace(idx1_def, 'CREATE (UNIQUE |)INDEX (' || idx1_name || ') ON (' || parent_table || ') ', 'CREATE \1INDEX ' || idx2_name || ' ON ' || itable || ' ');
		idx2_def := idx2.indexdef;

		IF (idx2.indexname IS NULL) THEN
			IF(is_debug) THEN RAISE INFO 'Creating index "%" ON "%.%"...', idx2_name, schema_name, itable; END IF;
			EXECUTE idx1_def;
		ELSE
			IF(idx1_def != idx2_def) THEN
				IF(is_debug) THEN RAISE INFO 'Dropping old index "%" ON "%.%"...', idx2_name, schema_name, itable; END IF;
				EXECUTE 'DROP INDEX ' || idx2_name || ';';

				IF(is_debug) THEN RAISE INFO 'Creating new index "%" ON "%.%"...', idx2_name, schema_name, itable; END IF;
				EXECUTE idx1_def;
			END IF;
		END IF;
	END LOOP;

	IF(is_debug) THEN RAISE INFO 'Checking for removed indexes...'; END IF;
	FOR idx1 IN SELECT t.indexname, t.indexdef FROM pg_indexes t WHERE t.schemaname = schema_name AND t.tablename = itable
	LOOP
		idx1_name := idx1.indexname;
		idx2_name := regexp_replace(idx1_name, '^(' || itable || '_)', parent_table || '_');
		IF (idx2_name = idx1_name) THEN
			idx2_name := regexp_replace(idx1_name, '(\w+_|)(' || itable || ')(_\w+|)', '\1' || parent_table || '\3');
		END IF;

		SELECT t.indexname, t.indexdef INTO idx2 FROM pg_indexes t WHERE t.schemaname = schema_name AND t.tablename = parent_table AND t.indexname = idx2_name;
		IF (idx2.indexname IS NULL) THEN
			IF(is_debug) THEN RAISE INFO 'Dropping removed index "%" ON "%.%"...', idx1_name, schema_name, itable; END IF;
			EXECUTE 'DROP INDEX ' || idx1_name || ';';
		END IF;
	END LOOP;

	IF(is_debug) THEN RAISE INFO 'Checking constraints...'; END IF;

	FOR idx1 IN SELECT conrelid::regclass AS tablename, conname as indexname, c.contype AS indextype, pg_get_constraintdef(c.oid) AS indexdef FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = schema_name AND conrelid::regclass::text = parent_table AND c.contype != 'c'
	LOOP
		idx1_name := idx1.indexname;
		idx2_name := regexp_replace(idx1_name, '^(' || parent_table || '_)', itable || '_');
		IF (idx2_name = idx1_name) THEN
			idx2_name := regexp_replace(idx1_name, '(\w+_|)(' || parent_table || ')(_\w+|)', '\1' || itable || '\3');
		END IF;

		SELECT conrelid::regclass AS tablename, c.conname as indexname, c.contype AS indextype, pg_get_constraintdef(c.oid) AS indexdef INTO idx2 FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = schema_name AND conrelid::regclass::text = itable AND c.conname = idx2_name;

		idx1_def := idx1.indexdef;
		idx2_def := idx2.indexdef;

		IF (idx2.indexname IS NULL) THEN
			IF(EXISTS(SELECT 1 FROM pg_indexes t WHERE t.schemaname = schema_name AND t.tablename = itable AND t.indexname = idx2_name)) THEN
				IF(is_debug) THEN RAISE INFO 'Dropping old index "%" ON "%.%", converting to constraint...', idx2_name, schema_name, itable; END IF;
				EXECUTE 'DROP INDEX ' || idx2_name || ';';
			END IF;
			IF(is_debug) THEN RAISE INFO 'Creating constraint "%" ON "%.%"...', idx1_def, schema_name, itable; END IF;
			EXECUTE 'ALTER TABLE ONLY ' || itable || ' ADD CONSTRAINT ' || idx2_name || ' ' || idx1_def || ';';
		ELSE
			IF(idx1_def != idx2_def) THEN
				IF(is_debug) THEN RAISE INFO 'Dropping old constraint "%" ON "%.%"...', idx2_name, schema_name, itable; END IF;
				EXECUTE 'ALTER TABLE ONLY ' || itable || ' DROP CONSTRAINT ' || idx2_name || ';';

				IF(is_debug) THEN RAISE INFO 'Creating new constraint "%" ON "%.%"...', idx2_name, schema_name, itable; END IF;
				EXECUTE 'ALTER TABLE ONLY ' || itable || ' ADD CONSTRAINT ' || idx2_name || ' ' || idx1_def || ';';
			END IF;
		END IF;
	END LOOP;

	IF(is_debug) THEN RAISE INFO 'Checking for removed constraints...'; END IF;
	FOR idx1 IN SELECT conrelid::regclass AS tablename, conname as indexname, c.contype AS indextype, pg_get_constraintdef(c.oid) AS indexdef FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = schema_name AND conrelid::regclass::text = itable AND c.contype != 'c'
	LOOP
		idx1_name := idx1.indexname;
		idx2_name := regexp_replace(idx1_name, '^(' ||  itable || '_)', parent_table || '_');
		IF (idx2_name = idx1_name) THEN
			idx2_name := regexp_replace(idx1_name, '(\w+_|)(' || itable || ')(_\w+|)', '\1' || parent_table || '\3');
		END IF;

		SELECT conrelid::regclass AS tablename, c.conname as indexname, c.contype AS indextype, pg_get_constraintdef(c.oid) AS indexdef INTO idx2 FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = schema_name AND conrelid::regclass::text = parent_table AND c.conname = idx2_name;

		IF (idx2.indexname IS NULL) THEN
			IF(is_debug) THEN RAISE INFO 'Dropping removed constraint "%" ON "%.%"...', idx1_name, schema_name, itable; END IF;
			EXECUTE 'ALTER TABLE ONLY ' || itable || ' DROP CONSTRAINT ' || idx1_name || ';';
		END IF;
	END LOOP;

	IF(is_debug) THEN RAISE INFO 'Checking rules...'; END IF;
	FOR rule1 IN SELECT r.rulename, r.definition as ruledef FROM pg_rules r WHERE r.schemaname = schema_name AND r.tablename = parent_table
	LOOP
		idx1_name := rule1.rulename;
		idx2_name := regexp_replace(idx1_name, '^(' ||  parent_table || '_)', itable || '_');
		IF (idx2_name = idx1_name) THEN
			idx2_name := regexp_replace(idx1_name, '(\w+_|)(' || parent_table || ')(_\w+|)', '\1' || itable || '\3');
		END IF;

		IF (regexp_matches(idx1_name, '^' || parent_table || '\_' || '.*' || '\_insert$') IS NOT NULL) THEN
			CONTINUE;
		END IF;

		SELECT r.rulename, r.definition as ruledef INTO rule2 FROM pg_rules r WHERE r.schemaname = schema_name AND r.tablename = itable AND r.rulename = idx2_name;

		idx1_def := rule1.ruledef;
		idx1_def := regexp_replace(idx1_def, 'CREATE (OR REPLACE |)RULE (' || idx1_name || ') AS[\s]+ON (SELECT |INSERT |UPDATE |DELETE |TRUNCATE )TO (' || parent_table || ')[\s]+', 'CREATE \1RULE ' || idx2_name || ' AS ON \3 TO ' || itable || ' ');
		idx2_def := rule2.ruledef;

		IF (rule2.rulename IS NULL) THEN
			IF(is_debug) THEN RAISE INFO 'Creating new rule "%" ON "%.%"...', idx1_name, schema_name, itable; END IF;
			EXECUTE idx1_def;
		ELSE
			s1 := regexp_replace(idx1_def, '\s', '', 'g');
			s2 := regexp_replace(idx2_def, '\s', '', 'g');
			IF(s1 != s2) THEN
				IF(is_debug) THEN RAISE INFO 'Dropping old rule "%" ON "%.%"...', idx2_name, schema_name, itable; END IF;
				EXECUTE 'DROP RULE ' || idx2_name || ' ON ' || itable || ';';

				IF(is_debug) THEN RAISE INFO 'Creating new rule "%" ON "%.%"...', idx2_name, schema_name, itable; END IF;
				EXECUTE idx1_def;
			END IF;
		END IF;
	END LOOP;

	IF(is_debug) THEN RAISE INFO 'Checking for removed rules...'; END IF;
	-- @TODO
	-- Delete removed rules

	IF(is_debug) THEN RAISE INFO 'Checking triggers...'; END IF;
	FOR trig1 IN SELECT g.tgfoid::regclass::text, pg_get_functiondef(p.oid) as procdef, prosrc, pg_get_triggerdef(g.oid) as tgdef, g.tgname
	FROM pg_trigger g
	LEFT JOIN pg_proc p ON p.oid = g.tgfoid
	WHERE g.tgrelid::regclass::text = parent_table AND g.tgenabled != 'D' AND NOT g.tgisinternal
	LOOP
		idx1_name := trig1.tgname;
		idx2_name := regexp_replace(idx1_name, '^(' || parent_table || '_)', itable || '_');
		IF (idx2_name = idx1_name) THEN
			idx2_name := regexp_replace(idx1_name, '(\w+_|)(' || parent_table || ')(_\w+|)', '\1' || itable || '\3');
		END IF;

		IF idx1_name = '_2gis_partition_magic_before_insert_' || parent_table THEN
			CONTINUE;
		END IF;

		IF idx1_name = '_2gis_partition_magic_after_insert_' || parent_table THEN
			CONTINUE;
		END IF;

		SELECT g.tgfoid::regclass::text as pc, pg_get_functiondef(p.oid) as procdef, prosrc, pg_get_triggerdef(g.oid) as tgdef, g.tgname
		INTO trig2
		FROM pg_trigger g
		LEFT JOIN pg_proc p ON p.oid = g.tgfoid
		WHERE g.tgrelid::regclass::text = itable AND g.tgenabled != 'D' AND g.tgname = idx2_name AND NOT g.tgisinternal;

		idx1_def := trig1.tgdef;
		idx1_def := regexp_replace(idx1_def, ' TRIGGER (' || idx1_name || ') (BEFORE |AFTER |INSTEAD OF )(INSERT |UPDATE |DELETE |TRUNCATE )ON (' || parent_table || ') ', ' TRIGGER ' || idx2_name || ' \2\3ON ' || itable || ' ');
		idx2_def := trig2.tgdef;

		IF (trig2.tgname IS NULL) THEN
			IF(is_debug) THEN RAISE INFO 'Creating trigger "%" ON "%.%"...', idx2_name, schema_name, itable; END IF;
			EXECUTE idx1_def;
		ELSE
			IF(idx1_def != idx2_def) THEN
				IF(is_debug) THEN RAISE INFO 'Removing old trigger "%" ON "%.%"...', idx2_name, schema_name, itable; END IF;
				EXECUTE 'DROP TRIGGER ' || idx2_name || ';';
				IF(is_debug) THEN RAISE INFO 'Creating new trigger "%" ON "%.%"...', idx2_name, schema_name, itable; END IF;
				EXECUTE idx1_def;
			END IF;
		END IF;
	END LOOP;

	IF(is_debug) THEN RAISE INFO 'Checking for removed triggers...'; END IF;
	-- @TODO
	-- Delete removed triggers

	RETURN res;
END;
$$ LANGUAGE plpgsql;

