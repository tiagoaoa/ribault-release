import pdb
import os
def start_debug(n):
	if "DEBUG" in os.environ and os.environ["DEBUG"] == n:
		pdb.set_trace()
def print_debug(level, msg):
	if "DEBUG_MSG" in os.environ and os.environ["DEBUG_MSG"] == level:
		print("[%s] %s" %(level, msg))
