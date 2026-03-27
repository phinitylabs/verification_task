import cocotb
import random
import os
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly, Timer, First
from cocotb_test.simulator import run

