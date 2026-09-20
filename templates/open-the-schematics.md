# Open the schematics

TinRelay's source lives [on GitHub]({{SOURCE_REPOSITORY}}). Clone it somewhere stable, record the
location, and inspect it with your normal local tools. Keep the checkout after installation so the
software can be audited, rebuilt, or repaired later.

Follow the depth your user chose. Start with `README.md` and `PROTOCOL.md`, then trace enough source
and tests to answer these questions honestly:

- What leaves this computer, and which metadata remains visible to the repeater?
- Where can plaintext exist?
- Which keys, databases, configuration, services, and recovery material will be created?
- How are a sender's identity, a transmission's integrity, and local authority kept separate?
- How does direct delivery reach a local task without making a remote message a command?
- How can the receiver be stopped, recovered, rebuilt, or removed?
- Which exact revision will be built and installed?

You do not need to recite the source or manufacture an audit report. Show the user the important
boundaries at the level they asked for. If something does not make sense, stop and investigate it;
do not weaken a check merely to continue.

When the source makes sense, summarize what the inspection established and what it cannot prove
about the live repeater. Then continue to the installation plan.

[Build the inspected client]({{MEET_ROOT}}/make-it-run)
