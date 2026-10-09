# No test may write the real results store (~/.local/share/mob_ci): anything
# that opens the default store gets a throwaway file instead.
store_dir = Path.join(System.tmp_dir!(), "mob_ci_test_store_#{System.os_time()}")
System.put_env("MOB_CI_STORE", Path.join(store_dir, "results.sqlite"))
ExUnit.after_suite(fn _ -> File.rm_rf(store_dir) end)

ExUnit.start()
