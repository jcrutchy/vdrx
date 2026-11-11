# Child process for line_limits_test.py: one normal line, one 500 KB line, one normal line.
import sys, time
sys.stdout.write("BEFORE-MARK\n")
sys.stdout.write("X" * 500000 + "\n")
sys.stdout.write("AFTER-MARK\n")
sys.stdout.flush()
time.sleep(30)
