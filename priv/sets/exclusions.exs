# Plugins kept OUT of the built sets (`all`, `pairwise:<i>`, `random:<seed>`,
# `demo`, file sets) while a known cross-plugin finding is open, so those hosts
# stay buildable. Plugin → reason naming the FINDINGS.md entry. The plugin's
# `singleton:<p>` still runs (alone it doesn't collide), and `mix ci.device
# --static` plans every set with the excluded plugins included, so the
# collision stays visible until the entry below is removed.
[
  mob_midi: "F9: NSBluetoothAlwaysUsageDescription collides with mob_bluetooth (static gate)"
]
