#!/usr/bin/perl -w


require "common.pl";

#The purpose of this is to repopulate the companies_* tables using the information that has been parsed from the filings. 

#reset the tables so that the ids restart from zero
$db->do("delete from companies");
$db->do("alter table companies auto_increment=0");
$db->do("delete from company_names");
$db->do("alter table company_names auto_increment=0");
$db->do("delete from company_locations");
$db->do("alter table company_locations auto_increment=0");




# ---- make company entries for each of the filers ----

$db->do("insert into companies (row_id, cik, company_name, irs_number, sic_category, source_type, source_id) select null, cik, match_name, max(irs_number), max(sic_code), 'filers', filer_id from filers group by cik");
$db->do("update companies set cw_id = concat('cw_',row_id)");

#put the names of the filers in the names table
#/* But put both varients in the names table.  If it has a former name, put that in the names table also.  Also strip off "%/___/" and put both varients in names. Include filing date and location if availible*/

$db->do("insert into company_names (name_id, cw_id, name, date, country_code, subdiv_code, source, source_row_id) select null,cw_id, match_name, filing_date, null, null, 'filer_match_name', filer_id from filers join filings using (filing_id) join companies on filers.cik = companies.cik group by companies.cik"); 

$db->do("insert into company_names (name_id, cw_id, name, date, country_code, subdiv_code, source, source_row_id) select null,cw_id, conformed_name, filing_date, null, null, 'filer_conformed_name', filer_id from filers join filings using (filing_id) join companies on filers.cik = companies.cik group by companies.cik"); 

#insert former names of filers into the names table
$db->do("insert into company_names (name_id, cw_id, name, date, source, source_row_id) select null,cw_id, former_name,date(name_change_date), 'filer_former_name', filer_id from filers join companies using (cik) where former_name is not null");

#now process the locations of the filers
#/* put the biz address, mail address, and name state suffix in locations with id*/
$db->do('insert into company_locations (location_id, cw_id, date, type, raw_address, street_1, street_2, city, state, postal_code) select null,cw_id,filing_date,"business",concat_ws(", ",business_street_1, business_street_2,business_city,business_state,business_zip) raw, business_street_1, business_street_2,business_city,business_state,business_zip from filers join companies using (cik) join filings using (filing_id) where business_street_1 is not null');
$db->do('insert into company_locations (location_id, cw_id, date, type, raw_address, street_1, street_2, city, state, postal_code) select null,cw_id,filing_date,"mailing",concat_ws(", ",mail_street_1, mail_street_2,mail_city,mail_state,mail_zip) raw, mail_street_1, mail_street_2,mail_city,mail_state,mail_zip from filers join companies using (cik) join filings using (filing_id) where mail_street_1 is not null');

#/* fill in un country and subdiv codes o the filers where possible */
$db->do("update company_locations,region_codes set company_locations.country_code = region_codes.country_code, company_locations.subdiv_code = region_codes.subdiv_code where company_locations.state = region_codes.code");

#fill in the sic hierarchy where we have sic codes
$db->do("update companies, (select cw_id,sic_category, sic_codes.industry_name, sic_sectors.sic_sector, sic_sectors.sector_name from companies join sic_codes on sic_category=sic_code join sic_sectors on sic_codes.sic_sector = sic_sectors.sic_sector) sic
set companies.industry_name = sic.industry_name,
companies.sic_sector = sic.sic_sector,
companies.sector_name = sic.sector_name
where companies.cw_id = sic.cw_id");


#----- create companies for the relationship companies -------


#create companies for relationship companies that have not already been assigned a cik
#TODO: skip 'companies' that match with strings in the non-companies table
$db->do("insert into companies (row_id, cik, company_name, source_type, source_id) select null, cik, clean_company, 'relationships', relationship_id from relationships left join companies using (cik) where companies.cik is null group by clean_company");
$db->do("update companies set cw_id = concat('cw_',row_id)");

#put those names into the names table
$db->do("insert into company_names (name_id, cw_id, name, source, source_row_id) select null,cw_id, clean_company, 'relationships_clean_company', relationship_id from relationships a join companies b on b.company_name = clean_company where b.source_type = 'relationships'");
$db->do("insert into company_names (name_id, cw_id, name, source, source_row_id) select null,cw_id, a.company_name, 'relationships_company_name', relationship_id from relationships a join companies b on b.company_name = clean_company where b.source_type = 'relationships'");

#process the relationships and attept to tag each one with a country and subdiv  for locationscode
&match_relationships_locations();

#put the relationships' locations that have been sucessfully tagged into the locations table
$db->do("insert into company_locations (location_id,cw_id,date,type,raw_address,country_code,subdiv_code) select null,cw_id,filing_date,'relation_loc',location, country_code,subdiv_code from companies join relationships on source_type = 'relationships' and companies.row_id = relationships.relationship_id and location is not null
join filings using (filing_id)");


# --- FIGURE OUT WHAT THE BEST (MOST COMPLETE) ADDRESS INFO IS
#first choice is business address, but if that is null, using mailing, if that is null, use the location with both country and state, if that is null use whatever is left. 
$db-do("update companies, 
(select cw_id, 
if (a is not null,a,
  if (b is not null, b, 
    if (c is not null, c,d)
  )
)
best_id from
(select cw_id, max(biz_loc) a,max(mail_loc) b,max(rel_loc) c,max(s_rel_loc) d from (select cw_id,if ((type = 'business' and street_1 is not null),location_id,null) biz_loc, 
if ((type = 'mailing' and street_1 is not null),location_id,null) mail_loc,
if ((type = 'relation_l' and subdiv_code is not null),location_id,null) rel_loc,
if ((type = 'relation_l'),location_id,null) s_rel_loc
from company_locations ) merged group by cw_id) best) best_loc
set companies.best_location_id = best_loc.best_id
where companies.cw_id = best_loc.cw_id");


# --- PUT THE RELATIONS IN THE COMPANY RELATIONS TABLE -------
$db->do("insert into company_relations (relation_id, source_cw_id, target_cw_id, relation_origin, origin_id) select null, c.cw_id, d.cw_id, 'relationships', a.relationship_id from relationships a join filings b using (filing_id) join companies c on b.cik = c.cik join companies d on a.clean_company = d.company_name");

# update the companies table with the counts of parents and children
$db->do("update companies, (select companies.cw_id,
 count(distinct parents.target_cw_id) num_parents ,count(distinct kids.target_cw_id) num_children 
from companies
left join company_relations kids on companies.cw_id = kids.source_cw_id
left join company_relations parents on companies.cw_id = parents.target_cw_id
group by companies.cw_id) relcount
set companies.num_parents = relcount.num_parents,
companies.num_children = relcount.num_children
where companies.cw_id = relcount.cw_id");



# ------ SUBROUTINE FOR MATCHING RELATIONSHIP LOCATIONS ---
sub match_relationships_locations() {
	#/* a) match all that have two capital letters, and are in the table of us state codes  */

	$db->do('update relationships, un_country_subdivisions set relationships.subdiv_code = subdivision_code, relationships.country_code = "US" where location=subdivision_code and un_country_subdivisions.country_code = "US"');

	#/* b) tag as DE all that contain the string "Delaware"  misses some multiply tagged locations  */

	$db->do('update relationships set subdiv_code = "DE", country_code = "US" where location like "%Delaware%"');

	#/*  c) match all state names (including "Georgia", which can be confused) */

	$db->do('update relationships,un_country_subdivisions set relationships.country_code = un_country_subdivisions.country_code, relationships.subdiv_code = un_country_subdivisions.subdivision_code where relationships.location = subdivision_name and un_country_subdivisions.country_code = "US" and relationships.country_code is null');

	#/* d) match all country names that are not confuseable (exclude georgia) */

	$db->do('update relationships,un_countries set relationships.country_code = un_countries.country_code where relationships.location = country_name and country_name != "Georgia" and relationships.country_code is null');

	#/* e) match alaised variants "caymen" "US", "USA", "U.S.A", "United States of America" tag caymen island varients */

	$db->do('update relationships, un_country_aliases set relationships.country_code = un_country_aliases.country_code, relationships.subdiv_code = un_country_aliases.subdiv_code where location = country_name');

	#/* f)  match where location in formate  "City Name, CA"  */

	$db->do('update relationships, un_country_subdivisions set relationships.country_code = "US", relationships.subdiv_code = right(location,2) where location like "%, __" and right(location,2) in (select subdivision_code from un_country_subdivisions where country_code = "US")');

	# /* f) match canadian proviences */

	$db->do('update relationships, un_country_subdivisions set relationships.country_code = "CA", subdiv_code = un_country_subdivisions.subdivision_code where relationships.country_code is null and location = subdivision_name and location in (select subdivision_name from un_country_subdivisions where country_code = "CA")');

	# /* g) tag entries that are definitly not geographies  $, %, incorporated in */

	# /*  strip out "a % corporation" and retag countries and states? */

}
__END__;

#everything below is not run, notes  and cruft included here for reference
/* add locations to company names */

/* collapse all redundant company names entries */

/* put the stripped-off locations from the company names as locations also */

insert into company_locations select null,cw_id,filing_date,"name_state", null,null,null,null, (CASE
WHEN conformed_name like "%/__/"  THEN left(right(conformed_name,3),2)
WHEN conformed_name like "%\\\__\\"  THEN left(right(conformed_name, 3),2)
WHEN conformed_name like "%/__" THEN right(conformed_name, 2)
ELSE null
END) as state,null,null,null,null from filers join companies using (cik) join filings using (filing_id)  having state is not null;


/* MAKE ENTRIES FOR THE RELATIONSHIPS COMPANIES */

/* Mark to Ignore names that are obviously headers or exact match with country or state name.*/

/* match clean company names to clean cik lookup */
/* create companies and names entries for cik_lookup names that are matched */

/* match clean companies to existing company names */
/* add remaining names as companies */
/* match newly added non-cik companies to eachother*/

/* add relationships to company_relations table */


/* ADD URL FOR DOWNLOADING THE FILING FROM SEC TO THE FILINGS TABLE */



