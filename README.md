# Room scanner (iPhone) - build only

An iPhone app that scans rooms with the LiDAR camera (Apple RoomPlan) and sends them to a self-hosted dashboard.
This repository only exists so GitHub Actions can build it: every push builds an unsigned `.ipa` for sideloading
(the **HomeMap-ipa** artifact) and runs the unit tests and a screenshot check of every screen.

There is nothing to configure here: the app is paired with its server at runtime.
