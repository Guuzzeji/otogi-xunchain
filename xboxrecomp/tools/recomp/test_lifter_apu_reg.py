"""A dword at a fixed APU register address calls the register model.

As a plain memory access each one faults into the model through the
exception handler. DirectSound writes several registers a voice every frame,
and in Otogi that was about 200 faults a frame on the game thread.
"""
import unittest

from .disasm import Instruction, Operand
from .lifter import Lifter


def _lift(mnemonic, op_str, operands):
    insn = Instruction(0x0012D830, 5, mnemonic, op_str, "",
                       operands=list(operands))
    return " ".join(Lifter().lift_instruction(insn))


def _mem(disp, size=4, base=None):
    return Operand(type="mem", mem_disp=disp, mem_size=size, mem_base=base)


def _reg(name):
    return Operand(type="reg", reg=name)


class ApuRegTest(unittest.TestCase):

    def test_store(self):
        out = _lift("mov", "dword ptr [0xfe8202fc], eax",
                    [_mem(0xFE8202FC), _reg("eax")])
        self.assertIn("xbox_apu_wr32(0xFE8202FCu, eax);", out)

    def test_load(self):
        out = _lift("mov", "ecx, dword ptr [0xfe820010]",
                    [_reg("ecx"), _mem(0xFE820010)])
        self.assertIn("ecx = xbox_apu_rd32(0xFE820010u);", out)

    def test_other_accesses_stay_memory(self):
        for op in (_mem(0xFE8202FC, base="esi"), _mem(0xFE8202FC, size=1),
                   _mem(0xFD000000), _mem(0x145C50)):
            out = _lift("mov", "", [op, _reg("eax" if op.mem_size == 4 else "al")])
            self.assertNotIn("xbox_apu", out)


if __name__ == "__main__":
    unittest.main()
