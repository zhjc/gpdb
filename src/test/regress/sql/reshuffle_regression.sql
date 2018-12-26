-- start_ignore
create extension if not exists gp_debug_numsegments;
create language plpythonu;
-- end_ignore

drop schema if exists test_reshuffle_regression cascade;
create schema test_reshuffle_regression;
set search_path=test_reshuffle_regression,public;

--
-- derived from src/pl/plpython/sql/plpython_trigger.sql
--
-- with some hacks we could insert data into incorrect segments, reshuffle node
-- should tolerant this.
--

-- with this trigger the inserted data is always hacked to '345'
create function trig345() returns trigger language plpythonu as $$
    TD["new"]["data"] = '345'
    return 'modify'
$$;

select gp_debug_set_create_table_default_numsegments(2);
create table b(data int);
select gp_debug_reset_create_table_default_numsegments();

-- by default '345' should be inserted on seg0
insert into b values ('345');
select gp_segment_id, * from b;

truncate b;

create trigger b_t before insert on b for each row execute procedure trig345();

-- however with the trigger it is inserted on seg1
insert into b select i from generate_series(1, 10) i;
select gp_segment_id, * from b;

-- reshuffle node should tolerant it
alter table b expand table;
select gp_segment_id, * from b;

--
-- derived from gp_upgrade_cornercases.sql
--
-- for inherited tables the parent and its children are allowed to have
-- different numsegments, this happens when a child is expanded before its
-- parent.  then when expanding the parent its children are also expanded, so
-- the child is re-expanded although there is nothing to do.  reshuffle node
-- should ignore these already expanded children instead of raising an error.
--

select gp_debug_set_create_table_default_numsegments(1);
create table root2 (a int, b int, c int) distributed randomly;
create table child2 (d int) inherits (root2);
select gp_debug_reset_create_table_default_numsegments();

insert into root2 values (1, 2, 3), (4, 5, 6), (7, 8, 9);
insert into child2 select i, i+1, i+2, i+3 from generate_series(100, 199) i;

select localoid::regclass, numsegments from gp_distribution_policy
 where localoid in ('child2'::regclass, 'root2'::regclass);

-- expand the child first
alter table child2 expand table;
-- then expand the parent, so the child is re-expanded
alter table root2 expand table;

-- verify that data has been redistributed
select count(*) > 0 from child2 where gp_segment_id <> 0;
-- verify the data integration after redistribution
select count(*) from child2;
-- verify the numsegments property after redistribution
select localoid::regclass, numsegments from gp_distribution_policy
 where localoid in ('child2'::regclass, 'root2'::regclass);

--
-- variant of above case: only child is unexpanded
--

drop table root2 cascade;

select gp_debug_set_create_table_default_numsegments('full');
create table root2 (a int, b int, c int) distributed randomly;
select gp_debug_set_create_table_default_numsegments(1);
create table child2 (d int) inherits (root2);
select gp_debug_reset_create_table_default_numsegments();

insert into root2 values (1, 2, 3), (4, 5, 6), (7, 8, 9);
insert into child2 select i, i+1, i+2, i+3 from generate_series(100, 199) i;

-- expand only root or child is not supported
alter table only root2 expand table;
alter table only child2 expand table;

alter table root2 expand table;

-- verify that data has been redistributed
select count(*) > 0 from child2 where gp_segment_id <> 0;
-- verify the data integration after redistribution
select count(*) from child2;
-- verify the numsegments property after redistribution
select localoid::regclass, numsegments from gp_distribution_policy
 where localoid in ('child2'::regclass, 'root2'::regclass);