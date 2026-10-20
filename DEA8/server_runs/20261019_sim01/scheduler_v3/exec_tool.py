"""Resource envelope for one unmodified Vivado simulation tool invocation."""
import os
import resource
import sys

cpu = int(sys.argv[1])
os.sched_setaffinity(0, {cpu})
os.nice(10)
resource.setrlimit(resource.RLIMIT_AS, (32 * 1024**3, 32 * 1024**3))
os.environ['OMP_NUM_THREADS'] = '1'
os.environ['OPENBLAS_NUM_THREADS'] = '1'
os.environ['MKL_NUM_THREADS'] = '1'
os.execvpe(sys.argv[2], sys.argv[2:], os.environ)
