# Build the inspected client

Prepare one bounded plan for the exact source you inspected: any missing Crystal, libsodium, or
SQLite prerequisites; the repository's real tests; the release build; the installation path; and
the final version check. Explain what each missing prerequisite changes on this computer.

Ask your user to approve that whole plan. Do not install packages, build, or write outside the
checkout until they agree. Ask again only if the scope materially changes.

Run the repository's checks and build the client. Install it somewhere the user approved and
ordinary shells already search. Do not silently alter shell startup files, change `PATH`, assume
global privileges, or discard the inspected checkout. Investigate failures instead of weakening
tests or substituting an uninspected artifact.

Finish with the installed program, invoked by name:

```sh
tinrelay version
```

Show the user the installed version and exact source revision. Explain what passed and any check
that did not run. Only then {{AFTER_BUILD_LINK}}.
