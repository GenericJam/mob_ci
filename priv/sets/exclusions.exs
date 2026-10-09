# Plugins kept OUT of the built sets (`all`, `pairwise:<i>`, `random:<seed>`,
# `demo`, file sets) while a known cross-plugin finding is open, so those hosts
# stay buildable. Plugin → reason naming the FINDINGS.md entry; the last one was
# `mob_midi: "F9: NSBluetoothAlwaysUsageDescription collides with mob_bluetooth"`,
# removed when mob_dev 0.7.19 resolved F9. A parked plugin's `singleton:<p>`
# still runs (alone it doesn't collide), and `mix ci.device --static` plans
# every set with the parked plugins included, so the collision stays visible
# until its entry is removed.
[]
