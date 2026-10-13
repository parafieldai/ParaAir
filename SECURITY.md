# Security policy

Last updated: 2026-10-13

## Reporting a vulnerability

Report security problems privately through GitHub's private vulnerability reporting:

**[Report a vulnerability](https://github.com/parafieldai/ParaAir/security/advisories/new)** (Security tab > Report a vulnerability)

Never put security problems in public issues, pull requests or discussions, including a "please contact me" note that describes the problem.

Please include:

- what is affected (Mac app, `paraair` CLI, FSKit extension, JuiceFS bridge, ParaAir Cloud client, the landing page) and the version or commit
- steps to reproduce, and what an attacker gains
- any proof of concept, with your own test data only

You will get a reply in the private advisory. Confirmed issues are fixed in a release and published as a security advisory that credits you, unless you ask us not to.

Reports about the hosted ParaAir Cloud service, which is not in this repository, use the same form.

## Scope and rules

- Test only with your own Mac, storage buckets and accounts. Do not access other people's data or storage.
- No denial of service, social engineering or physical attacks.
- Do not include real credentials, bucket names or personal data in a report; describe them instead.

## Supported versions

ParaAir is an alpha. Only the latest release receives security fixes.
