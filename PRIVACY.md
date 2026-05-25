# Privacy Policy

Last updated: May 25, 2026

This policy applies to `metaBrain`, `MetaBrainCore`, `mb`, and
`MetaBrainExplorer`.

## Summary

metaBrain and MetaBrainExplorer are local-first tools. They do not require an
account, login, subscription, cloud service, or remote database.

We do not collect, sell, rent, or share personal information through these
tools. We do not run analytics, advertising SDKs, tracking SDKs, or a
project-operated telemetry service. We do not receive or keep server logs for
your use of the app because the app does not connect to a project-operated
server.

## Local Data

metaBrain stores the documents you choose to create or open in a local
LevelDB-backed database, usually named `store.leveldb`. MetaBrainExplorer lets
you browse and edit a metaBrain database folder that you select on your Mac.

The content of your documents, metadata, tags, references, search index, and
version history stays on your device or in storage locations you control. The
tools do not upload this content to us.

MetaBrainExplorer may remember local app preferences, such as recently selected
store locations, using Apple platform storage. Those preferences remain local to
your device and are used only to make the app easier to reopen.

## Network Use

MetaBrainExplorer does not need a network connection to browse or edit a local
metaBrain database.

The `mb` command-line tool includes a version-check command that can contact
GitHub when you ask it to check for newer releases. That request is handled by
GitHub under GitHub's own privacy practices. We do not receive document content
from that check.

## Diagnostics And Support

The tools do not include project-operated crash reporting or analytics. Apple
may provide developers with App Store diagnostics if a user chooses to share
diagnostics with Apple, subject to Apple's privacy policies and settings.

If you contact the project through GitHub Issues, pull requests, email, or any
other support channel, we receive only the information you choose to provide.
Please avoid sharing private document contents in public issue reports.

## Changes

We may update this policy as the project evolves. Material changes will be made
in this repository.
