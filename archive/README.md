# Historical material — do not use as the current status gate

The original handover DOCX/PDF, spreadsheets and migration package are retained
for continuity. They contain status at their creation date and can have old rack
labels or assumptions. Current status and corrected inventory live at the root.

In particular, `underlay-migration/SN5600_Numbered31/migrate.py` preflight
expects only the original loopback BGP network. It can stop on valid client
/31 network advertisements added later. Do not remove those routes to satisfy
this archival check. It also relies on switch-local migration baseline files
which are not captured in this repository.

No DSX Air/Nitro configuration is presented as a production configuration.
Earlier lab packages, rejected draft drawings and unrelated upload photographs
are excluded from the runnable handover. Their role in project history is
described in the timeline rather than mixing them into the production package.
