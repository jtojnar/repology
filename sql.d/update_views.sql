-- Copyright (C) 2016-2018 Dmitry Marakasov <amdmi3@amdmi3.ru>
--
-- This file is part of repology
--
-- repology is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- repology is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with repology.  If not, see <http://www.gnu.org/licenses/>.

-- name: update_views

REFRESH MATERIALIZED VIEW CONCURRENTLY metapackage_repocounts;
REFRESH MATERIALIZED VIEW CONCURRENTLY repo_metapackages;
REFRESH MATERIALIZED VIEW CONCURRENTLY category_metapackages;
REFRESH MATERIALIZED VIEW CONCURRENTLY maintainer_metapackages;
REFRESH MATERIALIZED VIEW CONCURRENTLY maintainers;
REFRESH MATERIALIZED VIEW CONCURRENTLY url_relations;

-- package stats
INSERT INTO repositories (
	name,
	num_packages,
	num_packages_newest,
	num_packages_outdated,
	num_packages_ignored,
	num_packages_unique,
	num_packages_devel,
	num_packages_legacy,
	num_packages_incorrect,
	num_packages_untrusted,
	num_packages_noscheme,
	num_packages_rolling
)
SELECT
	repo,
	sum(num_packages),
	sum(num_packages_newest),
	sum(num_packages_outdated),
	sum(num_packages_ignored),
	sum(num_packages_unique),
	sum(num_packages_devel),
	sum(num_packages_legacy),
	sum(num_packages_incorrect),
	sum(num_packages_untrusted),
	sum(num_packages_noscheme),
	sum(num_packages_rolling)
FROM repo_metapackages
GROUP BY repo
ON CONFLICT (name)
DO UPDATE SET
	num_packages = EXCLUDED.num_packages,
	num_packages_newest = EXCLUDED.num_packages_newest,
	num_packages_outdated = EXCLUDED.num_packages_outdated,
	num_packages_ignored = EXCLUDED.num_packages_ignored,
	num_packages_unique = EXCLUDED.num_packages_unique,
	num_packages_devel = EXCLUDED.num_packages_devel,
	num_packages_legacy = EXCLUDED.num_packages_legacy,
	num_packages_incorrect = EXCLUDED.num_packages_incorrect,
	num_packages_untrusted = EXCLUDED.num_packages_untrusted,
	num_packages_noscheme = EXCLUDED.num_packages_noscheme,
	num_packages_rolling = EXCLUDED.num_packages_rolling;

INSERT INTO repositories (
	name,
	num_maintainers
)
SELECT
	repo,
	count(DISTINCT maintainer)
FROM (
	SELECT
		repo,
		unnest(maintainers) AS maintainer
	FROM packages
) AS temp
GROUP BY repo
ON CONFLICT (name)
DO UPDATE SET
	num_maintainers = EXCLUDED.num_maintainers;

-- metapackage stats
INSERT INTO repositories (
	name,
	num_metapackages,
	num_metapackages_unique,
	num_metapackages_newest,
	num_metapackages_outdated,
	num_metapackages_comparable
)
SELECT
	repo,
	count(*),
	count(*) FILTER (WHERE repo_metapackages.unique),
	count(*) FILTER (WHERE NOT repo_metapackages.unique AND (num_packages_newest > 0 OR num_packages_devel > 0) AND num_packages_outdated = 0),
	count(*) FILTER (WHERE num_packages_outdated > 0),
	count(*) FILTER (WHERE
		-- newest
		(NOT repo_metapackages.unique AND (num_packages_newest > 0 OR num_packages_devel > 0) AND num_packages_outdated = 0) OR
		-- outdated
		(num_packages_outdated > 0) OR
		-- problematic subset
		(num_packages_incorrect > 0)
	)
FROM repo_metapackages
GROUP BY repo
ON CONFLICT (name)
DO UPDATE SET
	num_metapackages = EXCLUDED.num_metapackages,
	num_metapackages_unique = EXCLUDED.num_metapackages_unique,
	num_metapackages_newest = EXCLUDED.num_metapackages_newest,
	num_metapackages_outdated = EXCLUDED.num_metapackages_outdated,
	num_metapackages_comparable = EXCLUDED.num_metapackages_comparable;

-- problems
INSERT INTO problems (
	repo,
	name,
	effname,
	maintainer,
	problem
)
SELECT DISTINCT
	packages.repo,
	packages.name,
	packages.effname,
	unnest(CASE WHEN packages.maintainers = '{}' THEN '{null}' ELSE packages.maintainers END),
	'Homepage link "' ||
		links.url ||
		'" is dead (' ||
		CASE
			WHEN links.status=-1 THEN 'connect timeout'
			WHEN links.status=-2 THEN 'too many redirects'
			WHEN links.status=-4 THEN 'cannot connect'
			WHEN links.status=-5 THEN 'invalid url'
			WHEN links.status=-6 THEN 'DNS problem'
			ELSE 'HTTP error ' || links.status
		END ||
		') for more than a month.'
FROM packages
INNER JOIN links ON (packages.homepage = links.url)
WHERE
	(links.status IN (-1, -2, -4, -5, -6, 400, 404) OR links.status >= 500) AND
	(
		(links.last_success IS NULL AND links.first_extracted < now() - INTERVAL '30' DAY) OR
		links.last_success < now() - INTERVAL '30' DAY
	);

INSERT INTO problems (
	repo,
	name,
	effname,
	maintainer,
	problem
)
SELECT DISTINCT
	packages.repo,
	packages.name,
	packages.effname,
	unnest(CASE WHEN packages.maintainers = '{}' THEN '{null}' ELSE packages.maintainers END),
	'Homepage link "' ||
		links.url ||
		'" is a permanent redirect to "' ||
		links.location ||
		'" and should be updated'
FROM packages
INNER JOIN links ON (packages.homepage = links.url)
WHERE
	links.redirect = 301 AND
	replace(links.url, 'http://', 'https://') = links.location;

INSERT INTO problems(repo, name, effname, maintainer, problem)
SELECT DISTINCT
	repo,
	name,
	effname,
	unnest(CASE WHEN packages.maintainers = '{}' THEN '{null}' ELSE packages.maintainers END),
	'Homepage link "' || homepage || '" points to Google Code which was discontinued. The link should be updated (probably along with download URLs). If this link is still alive, it may point to a new project homepage.'
FROM packages
WHERE
	homepage SIMILAR TO 'https?://([^/]+.)?googlecode.com(/%)?' OR
	homepage SIMILAR TO 'https?://code.google.com(/%)?';

INSERT INTO problems(repo, name, effname, maintainer, problem)
SELECT DISTINCT
	repo,
	name,
	effname,
	unnest(CASE WHEN packages.maintainers = '{}' THEN '{null}' ELSE packages.maintainers END),
	'Homepage link "' || homepage || '" points to codeplex which was discontinued. The link should be updated (probably along with download URLs).'
FROM packages
WHERE
	homepage SIMILAR TO 'https?://([^/]+.)?codeplex.com(/%)?';

INSERT INTO problems(repo, name, effname, maintainer, problem)
SELECT DISTINCT
	repo,
	name,
	effname,
	unnest(CASE WHEN packages.maintainers = '{}' THEN '{null}' ELSE packages.maintainers END),
	'Homepage link "' || homepage || '" points to Gna which was discontinued. The link should be updated (probably along with download URLs).'
FROM packages
WHERE
	homepage SIMILAR TO 'https?://([^/]+.)?gna.org(/%)?';

INSERT INTO repositories (
	name,
	num_problems
)
SELECT
	repo,
	count(distinct effname)
FROM problems
GROUP BY repo
ON CONFLICT (name)
DO UPDATE SET
	num_problems = EXCLUDED.num_problems;

-- statistics
UPDATE statistics
SET
	num_packages = (SELECT count(*) FROM packages),
	num_metapackages = (SELECT count(*) FROM metapackage_repocounts WHERE NOT shadow_only),
	num_problems = (SELECT count(*) FROM problems),
	num_maintainers = (SELECT count(*) FROM maintainers);

-- cleanup stale links
DELETE FROM links WHERE last_extracted < now() - INTERVAL '1' MONTH;
