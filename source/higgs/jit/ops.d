/*****************************************************************************
*
*                      Higgs JavaScript Virtual Machine
*
*  This file is part of the Higgs project. The project is distributed at:
*  https://github.com/maximecb/Higgs
*
*  Copyright (c) 2012-2015, Maxime Chevalier-Boisvert. All rights reserved.
*
*  This software is licensed under the following license (Modified BSD
*  License):
*
*  Redistribution and use in source and binary forms, with or without
*  modification, are permitted provided that the following conditions are
*  met:
*   1. Redistributions of source code must retain the above copyright
*      notice, this list of conditions and the following disclaimer.
*   2. Redistributions in binary form must reproduce the above copyright
*      notice, this list of conditions and the following disclaimer in the
*      documentation and/or other materials provided with the distribution.
*   3. The name of the author may not be used to endorse or promote
*      products derived from this software without specific prior written
*      permission.
*
*  THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED
*  WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
*  MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
*  NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
*  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
*  NOT LIMITED TO PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
*  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
*  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
*  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
*  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*
*****************************************************************************/

module jit.ops;

import core.memory;
import core.stdc.string;
import core.stdc.math;
import std.stdio;
import std.string;
import std.array;
import std.stdint;
import std.conv;
import std.algorithm;
import std.traits;
import std.datetime;
import options;
import stats;
import parser.parser;
import ir.ir;
import ir.ops;
import ir.ast;
import ir.livevars;
import ir.analysis;
import runtime.vm;
import runtime.layout;
import runtime.object;
import runtime.string;
import runtime.gc;
import jit.codeblock;
import jit.x86;
import jit.moves;
import jit.util;
import jit.jit;
import core.sys.posix.dlfcn;

/// Instruction code generation function
alias GenFn = void function(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
);

/// Get an argument by index
void gen_get_arg(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // Get the first argument slot
    auto argSlot = instr.block.fun.argcVal.outSlot + 1;

    // Get the argument index
    auto idxOpnd = ctx.getWordOpnd(as, instr, 0, 32, scrRegs[0].opnd(32), false);
    assert (idxOpnd.isGPR);
    auto idxReg32 = idxOpnd.reg.opnd(32);
    auto idxReg64 = idxOpnd.reg.opnd(64);

    // Get the output operand
    auto opndOut = ctx.getOutOpnd(as, instr, 64);

    // Zero-extend the index to 64-bit
    as.mov(idxReg32, idxReg32);

    // Copy the word value
    auto wordSlot = X86Opnd(64, wspReg, 8 * argSlot, 8, idxReg64.reg);
    as.genMove(opndOut, wordSlot, scrRegs[1].opnd(64));

    // Copy the type value
    auto typeSlot = X86Opnd(8, tspReg, 1 * argSlot, 1, idxReg64.reg);
    as.mov(scrRegs[1].opnd(8), typeSlot);
    ctx.setOutTag(as, instr, scrRegs[1].reg(8));
}

void gen_make_value(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // Move the word value into the output word,
    // allow reusing the input register
    auto wordOpnd = ctx.getWordOpnd(as, instr, 0, 64, scrRegs[0].opnd(64), true);
    auto outOpnd = ctx.getOutOpnd(as, instr, 64, true);
    if (outOpnd != wordOpnd)
        as.mov(outOpnd, wordOpnd);

    // Get the type value from the second operand
    auto tagOpnd = ctx.getWordOpnd(as, instr, 1, 8, scrRegs[0].opnd(8));
    assert (tagOpnd.isGPR);
    ctx.setOutTag(as, instr, tagOpnd.reg);
}

void gen_get_word(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto wordOpnd = ctx.getWordOpnd(as, instr, 0, 64, scrRegs[0].opnd(64), true);
    auto outOpnd = ctx.getOutOpnd(as, instr, 64);

    as.mov(outOpnd, wordOpnd);

    ctx.setOutTag(as, instr, Tag.INT64);
}

void gen_get_tag(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto tagOpnd = ctx.getTagOpnd(as, instr, 0, scrRegs[0].opnd(8), true);
    auto outOpnd = ctx.getOutOpnd(as, instr, 32);

    if (tagOpnd.isImm)
    {
        as.mov(outOpnd, tagOpnd);
    }
    else if (outOpnd.isGPR)
    {
        as.movzx(outOpnd, tagOpnd);
    }
    else
    {
        as.movzx(scrRegs[0].opnd(32), tagOpnd);
        as.mov(outOpnd, scrRegs[0].opnd(32));
    }

    ctx.setOutTag(as, instr, Tag.INT32);
}

void gen_i32_to_f64(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 32, scrRegs[0].opnd(32), false, false);
    assert (opnd0.isReg);
    auto outOpnd = ctx.getOutOpnd(as, instr, 64);

    // Sign-extend the 32-bit integer to 64-bit
    as.movsx(scrRegs[1].opnd(64), opnd0);

    as.cvtsi2sd(X86Opnd(XMM0), opnd0);

    as.movq(outOpnd, X86Opnd(XMM0));
    ctx.setOutTag(as, instr, Tag.FLOAT64);
}

void gen_f64_to_i32(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 64, X86Opnd(XMM0), false, false);
    auto outOpnd = ctx.getOutOpnd(as, instr, 32);

    if (!opnd0.isXMM)
        as.movq(X86Opnd(XMM0), opnd0);

    // Cast to int64 and truncate to int32 (to match JS semantics)
    as.cvttsd2si(scrRegs[0].opnd(64), X86Opnd(XMM0));
    as.mov(outOpnd, scrRegs[0].opnd(32));

    ctx.setOutTag(as, instr, Tag.INT32);
}

void RMMOp(string op, size_t numBits, Tag tag)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // Should be mem or reg
    auto opnd0 = ctx.getWordOpnd(
        as,
        instr,
        0,
        numBits,
        scrRegs[0].opnd(numBits),
        true
    );

    // May be reg or immediate
    auto opnd1 = ctx.getWordOpnd(
        as,
        instr,
        1,
        numBits,
        scrRegs[1].opnd(numBits),
        true
    );

    // Get type information about the first argument
    auto arg0Type = ctx.getType(instr.getArg(0));

    // Allow reusing an input register for the output,
    // except for subtraction which is not commutative
    auto opndOut = ctx.getOutOpnd(as, instr, numBits, op != "sub");

    if (op == "imul")
    {
        // imul does not support memory operands as output
        auto outReg = opndOut.isReg? opndOut:scrRegs[2].opnd(numBits);

        // TODO: handle this at the peephole level, assert not happening here
        if (opnd0.isImm && opnd1.isImm)
        {
            as.mov(outReg, opnd0);
            as.mov(scrRegs[0].opnd(numBits), opnd1);
            as.imul(outReg, scrRegs[0].opnd(numBits));
        }
        else if (opnd0.isImm)
        {
            as.imul(outReg, opnd1, opnd0);
        }
        else if (opnd1.isImm)
        {
            as.imul(outReg, opnd0, opnd1);
        }
        else if (opnd0 == opndOut)
        {
            as.imul(outReg, opnd1);
        }
        else if (opnd1 == opndOut)
        {
            as.imul(outReg, opnd0);
        }
        else
        {
            as.mov(outReg, opnd0);
            as.imul(outReg, opnd1);
        }

        if (outReg != opndOut)
            as.mov(opndOut, outReg);
    }
    else
    {
        if (opnd0 == opndOut)
        {
            mixin(format("as.%s(opndOut, opnd1);", op));
        }
        else if (opnd1 == opndOut)
        {
            // Note: the operation has to be commutative for this to work
            mixin(format("as.%s(opndOut, opnd0);", op));
        }
        else
        {
            // Neither input operand is the output
            as.mov(opndOut, opnd0);
            mixin(format("as.%s(opndOut, opnd1);", op));
        }
    }

    // Set the output type tag
    ctx.setOutTag(as, instr, tag);

    // If the instruction has no exception/overflow target, stop
    if (instr.getTarget(0) is null)
        return;

    // If this is an add operation
    static if (op == "add")
    {
        // If we are adding something to 1 and there can be no overflow
        auto arg1Cst = cast(IRConst)instr.getArg(1);
        if (arg1Cst && arg1Cst.isInt32 && 
            arg1Cst.int32Val == 1 &&
            arg0Type.subMax)
        {
            // Jump directly to the successor block
            //writeln("BBV ovf elim: ", instr.block.fun.getName);
            return gen_jump(ver, ctx, instr, as);
        }
    }

    // Increment the count of overflow checks
    if (opts.stats)
    {
        as.pushfq();
        as.incStatCnt(&stats.numOvfChecks, scrRegs[0]);
        as.popfq();
    }

    auto branchNO = getBranchEdge(instr.getTarget(0), ctx, false);
    auto branchOV = getBranchEdge(instr.getTarget(1), ctx, false);

    // Generate the branch code
    ver.genBranch(
        as,
        branchNO,
        branchOV,
        delegate void(
            CodeBlock as,
            BlockVersion block,
            CodeFragment target0,
            CodeFragment target1,
            BranchShape shape
        )
        {
            final switch (shape)
            {
                case BranchShape.NEXT0:
                jo32Ref(as, vm, block, target1, 1);
                break;

                case BranchShape.NEXT1:
                jno32Ref(as, vm, block, target0, 0);
                break;

                case BranchShape.DEFAULT:
                jo32Ref(as, vm, block, target1, 1);
                jmp32Ref(as, vm, block, target0, 0);
            }
        }
    );
}

alias gen_add_i32 = RMMOp!("add", 32, Tag.INT32);
alias gen_sub_i32 = RMMOp!("sub", 32, Tag.INT32);
alias gen_mul_i32 = RMMOp!("imul", 32, Tag.INT32);
alias gen_and_i32 = RMMOp!("and", 32, Tag.INT32);
alias gen_or_i32 = RMMOp!("or", 32, Tag.INT32);
alias gen_xor_i32 = RMMOp!("xor", 32, Tag.INT32);

alias gen_add_i32_ovf = RMMOp!("add", 32, Tag.INT32);
alias gen_sub_i32_ovf = RMMOp!("sub", 32, Tag.INT32);
alias gen_mul_i32_ovf = RMMOp!("imul", 32, Tag.INT32);

void gen_add_ptr_i32(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // Should be mem or reg
    auto opnd0 = ctx.getWordOpnd(
        as,
        instr,
        0,
        64,
        scrRegs[0].opnd(64),
        false
    );

    // May be reg or immediate
    auto opnd1 = ctx.getWordOpnd(
        as,
        instr,
        1,
        32,
        scrRegs[1].opnd(32),
        true
    );

    auto opndOut = ctx.getOutOpnd(as, instr, 64);

    // Zero-extend the integer operand to 64-bits
    as.mov(scrRegs[1].opnd(32), opnd1);

    as.mov(opndOut, opnd0);
    as.add(opndOut, scrRegs[1].opnd);

    // Set the output type tag
    ctx.setOutTag(as, instr, Tag.RAWPTR);
}

void divOp(string op)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // Spill EAX and EDX (used by the idiv instruction)
    ctx.spillReg(as, EAX);
    ctx.spillReg(as, EDX);

    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 32, X86Opnd.NONE, true, false);
    auto opnd1 = ctx.getWordOpnd(as, instr, 1, 32, scrRegs[1].opnd(32), false, false);
    auto outOpnd = ctx.getOutOpnd(as, instr, 32);

    as.mov(EAX.opnd, opnd0);

    if (opnd1 == EDX.opnd(32))
    {
        assert (scrRegs[1] != RAX && scrRegs[1] != RDX);
        as.mov(scrRegs[1].opnd(32), opnd1);
        opnd1 = scrRegs[1].opnd(32);
    }

    // Sign-extend EAX into EDX:EAX
    as.cdq();

    // Signed divide/quotient EDX:EAX by r/m32
    as.idiv(opnd1);

    // Store the divisor or remainder into the output operand
    static if (op == "div")
        as.mov(outOpnd, EAX.opnd);
    else if (op == "mod")
        as.mov(outOpnd, EDX.opnd);
    else
        assert (false);

    // Set the output type tag
    ctx.setOutTag(as, instr, Tag.INT32);
}

alias gen_div_i32 = divOp!("div");
alias gen_mod_i32 = divOp!("mod");

void gen_not_i32(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 32, scrRegs[0].opnd(32), true);
    auto outOpnd = ctx.getOutOpnd(as, instr, 32);

    as.mov(outOpnd, opnd0);
    as.not(outOpnd);

    // Set the output type tag
    ctx.setOutTag(as, instr, Tag.INT32);
}

void ShiftOp(string op)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    //auto startPos = as.getWritePos;

    // TODO: need way to allow reusing arg 0 reg only, but not arg1
    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 32, X86Opnd.NONE, true);
    auto opnd1 = ctx.getWordOpnd(as, instr, 1, 8, X86Opnd.NONE, true);
    auto outOpnd = ctx.getOutOpnd(as, instr, 32, false);

    auto shiftOpnd = outOpnd;

    // If the shift amount is a constant
    if (opnd1.isImm)
    {
        // Truncate the shift amount bits
        opnd1 = X86Opnd(opnd1.imm.imm & 31);

        // If opnd0 is not shiftOpnd (or is a constant)
        if (opnd0 != shiftOpnd)
            as.mov(shiftOpnd, opnd0);
    }
    else
    {
        // Spill the CL register if needed
        if (opnd1 != CL.opnd(8) && outOpnd != CL.opnd(32))
            ctx.spillReg(as, CL);

        // If outOpnd is CL, the shift amount register
        if (outOpnd == CL.opnd(32))
        {
            // Use a different register for the shiftee
            shiftOpnd = scrRegs[0].opnd(32);
        }

        // If opnd0 is not shiftOpnd (or is a constant)
        if (opnd0 != shiftOpnd)
            as.mov(shiftOpnd, opnd0);

        // If the shift amount is not already in CL
        if (opnd1 != CL.opnd(8))
        {
            as.mov(CL.opnd, opnd1);
            opnd1 = CL.opnd;
        }
    }

    static if (op == "sal")
        as.sal(shiftOpnd, opnd1);
    else if (op == "sar")
        as.sar(shiftOpnd, opnd1);
    else if (op == "shr")
        as.shr(shiftOpnd, opnd1);
    else
        assert (false);

    if (shiftOpnd != outOpnd)
        as.mov(outOpnd, shiftOpnd);

    // Set the output type tag
    ctx.setOutTag(as, instr, Tag.INT32);
}

alias gen_lsft_i32 = ShiftOp!("sal");
alias gen_rsft_i32 = ShiftOp!("sar");
alias gen_ursft_i32 = ShiftOp!("shr");

void FPOp(string op)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    X86Opnd opnd0 = ctx.getWordOpnd(as, instr, 0, 64, X86Opnd(XMM0));
    X86Opnd opnd1 = ctx.getWordOpnd(as, instr, 1, 64, X86Opnd(XMM1));
    auto outOpnd = ctx.getOutOpnd(as, instr, 64);

    assert (opnd0.isReg && opnd1.isReg);

    if (opnd0.isGPR)
        as.movq(X86Opnd(XMM0), opnd0);
    if (opnd1.isGPR)
        as.movq(X86Opnd(XMM1), opnd1);

    static if (op == "add")
        as.addsd(X86Opnd(XMM0), X86Opnd(XMM1));
    else if (op == "sub")
        as.subsd(X86Opnd(XMM0), X86Opnd(XMM1));
    else if (op == "mul")
        as.mulsd(X86Opnd(XMM0), X86Opnd(XMM1));
    else if (op == "div")
        as.divsd(X86Opnd(XMM0), X86Opnd(XMM1));
    else
        assert (false);

    as.movq(outOpnd, X86Opnd(XMM0));

    // Set the output type tag
    ctx.setOutTag(as, instr, Tag.FLOAT64);
}

alias gen_add_f64 = FPOp!("add");
alias gen_sub_f64 = FPOp!("sub");
alias gen_mul_f64 = FPOp!("mul");
alias gen_div_f64 = FPOp!("div");

void HostFPOp(alias cFPFun, size_t arity = 1)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    assert (arity is 1 || arity is 2);

    // Spill the values live before the instruction
    ctx.spillValues(
        as,
        delegate bool(LiveInfo liveInfo, IRDstValue value)
        {
            return liveInfo.liveBefore(value, instr);
        }
    );

    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 64, X86Opnd.NONE, false, false);
    as.movq(X86Opnd(XMM0), opnd0);

    static if (arity is 2)
    {
        auto opnd1 = ctx.getWordOpnd(as, instr, 1, 64, X86Opnd.NONE, false, false);
        as.movq(X86Opnd(XMM1), opnd1);
    }

    auto outOpnd = ctx.getOutOpnd(as, instr, 64);

    // Call the host function
    // Note: we do not save the JIT regs because they are callee-saved
    as.ptr(scrRegs[0], &cFPFun);
    as.call(scrRegs[0]);

    // Store the output value into the output operand
    as.movq(outOpnd, X86Opnd(XMM0));

    ctx.setOutTag(as, instr, Tag.FLOAT64);
}

alias gen_sin_f64 = HostFPOp!(core.stdc.math.sin);
alias gen_cos_f64 = HostFPOp!(core.stdc.math.cos);
alias gen_sqrt_f64 = HostFPOp!(core.stdc.math.sqrt);
alias gen_ceil_f64 = HostFPOp!(core.stdc.math.ceil);
alias gen_floor_f64 = HostFPOp!(core.stdc.math.floor);
alias gen_log_f64 = HostFPOp!(core.stdc.math.log);
alias gen_exp_f64 = HostFPOp!(core.stdc.math.exp);
alias gen_pow_f64 = HostFPOp!(core.stdc.math.pow, 2);
alias gen_mod_f64 = HostFPOp!(core.stdc.math.fmod, 2);

void FPToStr(string fmt)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static refptr toStrFn(IRInstr curInstr, double f)
    {
        vm.setCurInstr(curInstr);

        auto str = getString(vm, to!wstring(format(fmt, f)));

        vm.setCurInstr(null);

        return str;
    }

    // Spill the values that are live before this instruction
    ctx.spillLiveBefore(as, instr);

    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 64, X86Opnd.NONE, false, false);

    auto outOpnd = ctx.getOutOpnd(as, instr, 64);

    as.saveJITRegs();

    // Call the host function
    as.ptr(cargRegs[0], instr);
    as.movq(cfpArgRegs[0].opnd, opnd0);
    as.ptr(scrRegs[0], &toStrFn);
    as.call(scrRegs[0]);

    as.loadJITRegs();

    // Store the output value into the output operand
    as.mov(outOpnd, cretReg.opnd);

    ctx.setOutTag(as, instr, Tag.STRING);
}

alias gen_f64_to_str = FPToStr!("%G");
alias gen_f64_to_str_lng = FPToStr!(format("%%.%sf", float64.dig));

void LoadOp(size_t memSize, bool signed, Tag tag)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // The pointer operand must be a register
    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 64, scrRegs[0].opnd(64));
    assert (opnd0.isGPR);

    // The offset operand may be a register or an immediate
    auto opnd1 = ctx.getWordOpnd(as, instr, 1, 32, scrRegs[1].opnd(32), true);

    auto outOpnd = ctx.getOutOpnd(as, instr, (memSize < 64)? 32:64);

    // Create the memory operand
    X86Opnd memOpnd;
    if (opnd1.isImm)
    {
        memOpnd = X86Opnd(memSize, opnd0.reg, cast(int32_t)opnd1.imm.imm);
    }
    else if (opnd1.isGPR)
    {
        // Zero-extend the offset from 32 to 64 bits
        as.mov(opnd1, opnd1);
        memOpnd = X86Opnd(memSize, opnd0.reg, 0, 1, opnd1.reg.reg(64));
    }
    else
    {
        assert (false, "invalid offset operand");
    }

    // If the output operand is a memory location
    if (outOpnd.isMem)
    {
        auto scrReg = scrRegs[2].opnd((memSize < 64)? 32:64);

        // Load to a scratch register first
        static if (memSize < 32)
        {
            static if (signed)
                as.movsx(scrReg, memOpnd);
            else
                as.movzx(scrReg, memOpnd);
        }
        else
        {
            as.mov(scrReg, memOpnd);
        }

        // Move the scratch register to the output
        as.mov(outOpnd, scrReg);
    }
    else
    {
        // Load to the output register directly
        static if (memSize == 8 || memSize == 16)
        {
            static if (signed)
                as.movsx(outOpnd, memOpnd);
            else
                as.movzx(outOpnd, memOpnd);
        }
        else
        {
            as.mov(outOpnd, memOpnd);
        }
    }

    // Set the output type tag
    ctx.setOutTag(as, instr, tag);
}

alias gen_load_u8 = LoadOp!(8, false, Tag.INT32);
alias gen_load_u16 = LoadOp!(16, false, Tag.INT32);
alias gen_load_u32 = LoadOp!(32, false, Tag.INT32);
alias gen_load_u64 = LoadOp!(64, false, Tag.INT64);
alias gen_load_i8 = LoadOp!(8, true , Tag.INT32);
alias gen_load_i16 = LoadOp!(16, true , Tag.INT32);
alias gen_load_i32 = LoadOp!(32, true , Tag.INT32);
alias gen_load_i64 = LoadOp!(64, true , Tag.INT64);
alias gen_load_f64 = LoadOp!(64, false, Tag.FLOAT64);
alias gen_load_refptr = LoadOp!(64, false, Tag.REFPTR);
alias gen_load_string = LoadOp!(64, false, Tag.STRING);
alias gen_load_rawptr = LoadOp!(64, false, Tag.RAWPTR);
alias gen_load_funptr = LoadOp!(64, false, Tag.FUNPTR);

void StoreOp(size_t memSize, Tag tag)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // The pointer operand must be a register
    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 64, scrRegs[0].opnd(64));
    assert (opnd0.isGPR);

    // The offset operand may be a register or an immediate
    auto opnd1 = ctx.getWordOpnd(as, instr, 1, 32, scrRegs[1].opnd(32), true);

    // The value operand may be a register or an immediate
    auto opnd2 = ctx.getWordOpnd(as, instr, 2, memSize, scrRegs[2].opnd(memSize), true);

    // Create the memory operand
    X86Opnd memOpnd;
    if (opnd1.isImm)
    {
        memOpnd = X86Opnd(memSize, opnd0.reg, cast(int32_t)opnd1.imm.imm);
    }
    else if (opnd1.isGPR)
    {
        // Zero-extend the offset from 32 to 64 bits
        as.mov(opnd1, opnd1);
        memOpnd = X86Opnd(memSize, opnd0.reg, 0, 1, opnd1.reg.reg(64));
    }
    else
    {
        assert (false, "invalid offset operand");
    }

    // Store the value into the memory location
    as.mov(memOpnd, opnd2);
}

alias gen_store_u8 = StoreOp!(8, Tag.INT32);
alias gen_store_u16 = StoreOp!(16, Tag.INT32);
alias gen_store_u32 = StoreOp!(32, Tag.INT32);
alias gen_store_u64 = StoreOp!(64, Tag.INT64);
alias gen_store_i8 = StoreOp!(8, Tag.INT32);
alias gen_store_i16 = StoreOp!(16, Tag.INT32);
alias gen_store_i32 = StoreOp!(32, Tag.INT32);
alias gen_store_i64 = StoreOp!(64, Tag.INT64);
alias gen_store_f64 = StoreOp!(64, Tag.FLOAT64);
alias gen_store_refptr = StoreOp!(64, Tag.REFPTR);
alias gen_store_rawptr = StoreOp!(64, Tag.RAWPTR);
alias gen_store_funptr = StoreOp!(64, Tag.FUNPTR);

void TagTestOp(Tag tag)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    //as.printStr(instr.toString);
    //as.printStr("    " ~ instr.block.fun.getName);

    if (opts.save_tag_tests)
        regTagTest(ver);

    // Get an operand for the value's type
    auto tagOpnd = ctx.getTagOpnd(as, instr, 0, X86Opnd.NONE, true);

    auto testResult = TestResult.UNKNOWN;

    // If the type is available through basic block versioning
    if (tagOpnd.isImm)
    {
        // Get the known type
        auto knownTag = cast(Tag)tagOpnd.imm.imm;

        // Get the test result
        testResult = (tag is knownTag)? TestResult.TRUE:TestResult.FALSE;
    }

    // If the type analysis was run
    if (opts.load_tag_tests)
    {
        // Get the type analysis result for this value at this instruction
        auto anaResult = getTagTestResult(ver);

        //writeln("result: ", anaResult);

        // If the analysis yields a known result
        if (anaResult != TestResult.UNKNOWN)
        {
            // If there is a contradiction between versioning and the analysis
            if (testResult != TestResult.UNKNOWN && anaResult != testResult)
            {
                writeln(
                    "type analysis contradiction for:\n",
                     instr, "\n",
                    "analysis result:\n",
                    anaResult, "\n",
                    "versioning result:\n",
                    testResult, "\n",
                    "in:\n",
                    instr.block,
                    "\n"
                );
                assert (false);
            }

            testResult = anaResult;
        }
    }

    // If the type test result is known
    if (testResult != TestResult.UNKNOWN)
    {
        // Get the boolean value of the test
        auto boolResult = testResult is TestResult.TRUE;

        // If this instruction has many uses or is not followed by an if
        if (instr.hasManyUses || ifUseNext(instr) is false)
        {
            auto outOpnd = ctx.getOutOpnd(as, instr, 64);
            auto outVal = boolResult? TRUE:FALSE;
            as.mov(outOpnd, X86Opnd(outVal.word.int8Val));
            ctx.setOutTag(as, instr, Tag.BOOL);
        }

        // If our only use is an immediately following if_true
        if (ifUseNext(instr) is true)
        {
            // Get the branch edge
            auto targetIdx = boolResult? 0:1;
            auto branch = getBranchEdge(instr.next.getTarget(targetIdx), ctx, true);

            // Generate the branch code
            ver.genBranch(
                as,
                branch,
                null,
                delegate void(
                    CodeBlock as,
                    BlockVersion block,
                    CodeFragment target0,
                    CodeFragment target1,
                    BranchShape shape
                )
                {
                    final switch (shape)
                    {
                        case BranchShape.NEXT0:
                        break;

                        case BranchShape.NEXT1:
                        case BranchShape.DEFAULT:
                        jmp32Ref(as, vm, block, target0, 0);
                    }
                }
            );
        }

        return;
    }

    // Increment the stat counter for this specific kind of type test
    as.incStatCnt(stats.getTagTestCtr(instr.opcode.mnem), scrRegs[1]);

    if (opts.log_tag_tests)
    {
        writeln(instr);
        writeln("  ", instr.block.fun.getName);
    }

    // Compare against the tested type
    as.cmp(tagOpnd, X86Opnd(tag));

    // If this instruction has many uses or is not followed by an if_true
    if (instr.hasManyUses || ifUseNext(instr) is false)
    {
        // We must have a register for the output (so we can use cmov)
        auto outOpnd = ctx.getOutOpnd(as, instr, 64);
        X86Opnd outReg = outOpnd.isReg? outOpnd.reg.opnd(32):scrRegs[0].opnd(32);

        // Generate a boolean output value
        as.mov(outReg, X86Opnd(FALSE.word.int8Val));
        as.mov(scrRegs[1].opnd(32), X86Opnd(TRUE.word.int8Val));
        as.cmove(outReg.reg, scrRegs[1].opnd(32));

        // If the output register is not the output operand
        if (outReg != outOpnd)
            as.mov(outOpnd, outReg.reg.opnd(64));

        // Set the output type tag
        ctx.setOutTag(as, instr, Tag.BOOL);
    }

    // If our only use is an immediately following if_true
    if (ifUseNext(instr) is true)
    {
        // If the argument is not a constant, add type information
        // about the argument's type along the true branch
        CodeGenCtx trueCtx = ctx;
        if (auto dstArg = cast(IRDstValue)instr.getArg(0))
        {
            trueCtx = new CodeGenCtx(trueCtx);
            trueCtx.setTag(dstArg, tag);
        }

        // Get branch edges for the true and false branches
        auto branchT = getBranchEdge(instr.next.getTarget(0), trueCtx, false);
        auto branchF = getBranchEdge(instr.next.getTarget(1), ctx, false);

        // Generate the branch code
        ver.genBranch(
            as,
            branchT,
            branchF,
            delegate void(
                CodeBlock as,
                BlockVersion block,
                CodeFragment target0,
                CodeFragment target1,
                BranchShape shape
            )
            {
                final switch (shape)
                {
                    case BranchShape.NEXT0:
                    jne32Ref(as, vm, block, target1, 1);
                    break;

                    case BranchShape.NEXT1:
                    je32Ref(as, vm, block, target0, 0);
                    break;

                    case BranchShape.DEFAULT:
                    jne32Ref(as, vm, block, target1, 1);
                    jmp32Ref(as, vm, block, target0, 0);
                }
            }
        );
    }
}

alias gen_is_undef = TagTestOp!(Tag.UNDEF);
alias gen_is_null = TagTestOp!(Tag.NULL);
alias gen_is_bool = TagTestOp!(Tag.BOOL);
alias gen_is_int32 = TagTestOp!(Tag.INT32);
alias gen_is_int64 = TagTestOp!(Tag.INT64);
alias gen_is_float64 = TagTestOp!(Tag.FLOAT64);
alias gen_is_rawptr = TagTestOp!(Tag.RAWPTR);
alias gen_is_refptr = TagTestOp!(Tag.REFPTR);
alias gen_is_object = TagTestOp!(Tag.OBJECT);
alias gen_is_array = TagTestOp!(Tag.ARRAY);
alias gen_is_closure = TagTestOp!(Tag.CLOSURE);
alias gen_is_string = TagTestOp!(Tag.STRING);
alias gen_is_rope = TagTestOp!(Tag.ROPE);

void CmpOp(string op, size_t numBits)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // Check if this is a floating-point comparison
    static bool isFP = op.startsWith("f");

    // The first operand must be memory or register, but not immediate
    auto opnd0 = ctx.getWordOpnd(
        as,
        instr,
        0,
        numBits,
        scrRegs[0].opnd(numBits),
        false
    );

    // The second operand may be an immediate, unless FP comparison
    auto opnd1 = ctx.getWordOpnd(
        as,
        instr,
        1,
        numBits,
        scrRegs[1].opnd(numBits),
        isFP? false:true
    );

    // If this is an FP comparison
    if (isFP)
    {
        // Move the operands into XMM registers
        as.movq(X86Opnd(XMM0), opnd0);
        as.movq(X86Opnd(XMM1), opnd1);
        opnd0 = X86Opnd(XMM0);
        opnd1 = X86Opnd(XMM1);
    }

    // We must have a register for the output (so we can use cmov)
    auto outOpnd = ctx.getOutOpnd(as, instr, 64);
    X86Opnd outReg = outOpnd.isReg? outOpnd.reg.opnd(32):scrRegs[0].opnd(32);

    auto tmpReg = scrRegs[1].opnd(32);
    auto trueOpnd = X86Opnd(TRUE.word.int8Val);
    auto falseOpnd = X86Opnd(FALSE.word.int8Val);

    // Generate a boolean output only if this instruction has
    // many uses or is not followed by an if
    bool genOutput = (instr.hasManyUses || ifUseNext(instr) is false);

    // Integer comparison
    static if (op == "eq")
    {
        as.cmp(opnd0, opnd1);
        if (genOutput)
        {
            as.mov(outReg, falseOpnd);
            as.mov(tmpReg, trueOpnd);
            as.cmove(outReg.reg, tmpReg);
        }
    }
    else if (op == "ne")
    {
        as.cmp(opnd0, opnd1);
        if (genOutput)
        {
            as.mov(outReg, falseOpnd);
            as.mov(tmpReg, trueOpnd);
            as.cmovne(outReg.reg, tmpReg);
        }
    }
    else if (op == "lt")
    {
        as.cmp(opnd0, opnd1);
        if (genOutput)
        {
            as.mov(outReg, falseOpnd);
            as.mov(tmpReg, trueOpnd);
            as.cmovl(outReg.reg, tmpReg);
        }
    }
    else if (op == "le")
    {
        as.cmp(opnd0, opnd1);
        if (genOutput)
        {
            as.mov(outReg, falseOpnd);
            as.mov(tmpReg, trueOpnd);
            as.cmovle(outReg.reg, tmpReg);
        }
    }
    else if (op == "gt")
    {
        as.cmp(opnd0, opnd1);
        if (genOutput)
        {
            as.mov(outReg, falseOpnd);
            as.mov(tmpReg, trueOpnd);
            as.cmovg(outReg.reg, tmpReg);
        }
    }
    else if (op == "ge")
    {
        as.cmp(opnd0, opnd1);
        if (genOutput)
        {
            as.mov(outReg, falseOpnd);
            as.mov(tmpReg, trueOpnd);
            as.cmovge(outReg.reg, tmpReg);
        }
    }

    // Floating-point comparisons
    // From the Intel manual, EFLAGS are:
    // UNORDERED:    ZF, PF, CF ← 111;
    // GREATER_THAN: ZF, PF, CF ← 000;
    // LESS_THAN:    ZF, PF, CF ← 001;
    // EQUAL:        ZF, PF, CF ← 100;
    else if (op == "feq")
    {
        // feq:
        // True: 100
        // False: 111 or 000 or 001
        // False: JNE + JP
        as.ucomisd(opnd0, opnd1);
        if (genOutput)
        {
            as.mov(outReg, trueOpnd);
            as.mov(tmpReg, falseOpnd);
            as.cmovne(outReg.reg, tmpReg);
            as.cmovp(outReg.reg, tmpReg);
        }
    }
    else if (op == "fne")
    {
        // fne: 
        // True: 111 or 000 or 001
        // False: 100
        // True: JNE + JP
        as.ucomisd(opnd0, opnd1);
        if (genOutput)
        {
            as.mov(outReg, falseOpnd);
            as.mov(tmpReg, trueOpnd);
            as.cmovne(outReg.reg, tmpReg);
            as.cmovp(outReg.reg, tmpReg);
        }
    }
    else if (op == "flt")
    {
        as.ucomisd(opnd1, opnd0);
        if (genOutput)
        {
            as.mov(outReg, falseOpnd);
            as.mov(tmpReg, trueOpnd);
            as.cmova(outReg.reg, tmpReg);
        }
    }
    else if (op == "fle")
    {
        as.ucomisd(opnd1, opnd0);
        if (genOutput)
        {
            as.mov(outReg, falseOpnd);
            as.mov(tmpReg, trueOpnd);
            as.cmovae(outReg.reg, tmpReg);
        }
    }
    else if (op == "fgt")
    {
        as.ucomisd(opnd0, opnd1);
        if (genOutput)
        {
            as.mov(outReg, falseOpnd);
            as.mov(tmpReg, trueOpnd);
            as.cmova(outReg.reg, tmpReg);
        }
    }
    else if (op == "fge")
    {
        as.ucomisd(opnd0, opnd1);
        if (genOutput)
        {
            as.mov(outReg, falseOpnd);
            as.mov(tmpReg, trueOpnd);
            as.cmovae(outReg.reg, tmpReg);
        }
    }

    else
    {
        assert (false);
    }

    // If we are to generate output
    if (genOutput)
    {
        // If the output register is not the output operand
        if (outReg != outOpnd)
            as.mov(outOpnd, outReg.reg.opnd(64));

        // Set the output type tag
        ctx.setOutTag(as, instr, Tag.BOOL);
    }

    // If there is an immediately following if_true using this value
    if (ifUseNext(instr) is true)
    {
        // If this is a less-than comparison and the argument
        // is not a constant, mark the argument as being
        // submaximal along the true branch
        CodeGenCtx trueCtx = ctx;
        static if (op == "lt")
        {
            if (auto dstArg = cast(IRDstValue)instr.getArg(0))
            {
                trueCtx = new CodeGenCtx(trueCtx);
                ValType argType = trueCtx.getType(dstArg);
                argType.subMax = true;
                trueCtx.setType(dstArg, argType);
            }
        }

        // Get branch edges for the true and false branches
        auto branchT = getBranchEdge(instr.next.getTarget(0), trueCtx, false);
        auto branchF = getBranchEdge(instr.next.getTarget(1), ctx, false);

        // Generate the branch code
        ver.genBranch(
            as,
            branchT,
            branchF,
            delegate void(
                CodeBlock as,
                BlockVersion block,
                CodeFragment target0,
                CodeFragment target1,
                BranchShape shape
            )
            {
                // Integer comparison
                static if (op == "eq")
                {
                    final switch (shape)
                    {
                        case BranchShape.NEXT0:
                        jne32Ref(as, vm, block, target1, 1);
                        break;

                        case BranchShape.NEXT1:
                        je32Ref(as, vm, block, target0, 0);
                        break;

                        case BranchShape.DEFAULT:
                        je32Ref(as, vm, block, target0, 0);
                        jmp32Ref(as, vm, block, target1, 1);
                    }
                }
                else if (op == "ne")
                {
                    final switch (shape)
                    {
                        case BranchShape.NEXT0:
                        je32Ref(as, vm, block, target1, 1);
                        break;

                        case BranchShape.NEXT1:
                        jne32Ref(as, vm, block, target0, 0);
                        break;

                        case BranchShape.DEFAULT:
                        jne32Ref(as, vm, block, target0, 0);
                        jmp32Ref(as, vm, block, target1, 1);
                    }
                }
                else if (op == "lt")
                {
                    final switch (shape)
                    {
                        case BranchShape.NEXT0:
                        jge32Ref(as, vm, block, target1, 1);
                        break;

                        case BranchShape.NEXT1:
                        jl32Ref(as, vm, block, target0, 0);
                        break;

                        case BranchShape.DEFAULT:
                        jl32Ref(as, vm, block, target0, 0);
                        jmp32Ref(as, vm, block, target1, 1);
                    }
                }
                else if (op == "le")
                {
                    final switch (shape)
                    {
                        case BranchShape.NEXT0:
                        jg32Ref(as, vm, block, target1, 1);
                        break;

                        case BranchShape.NEXT1:
                        jle32Ref(as, vm, block, target0, 0);
                        break;

                        case BranchShape.DEFAULT:
                        jle32Ref(as, vm, block, target0, 0);
                        jmp32Ref(as, vm, block, target1, 1);
                    }
                }
                else if (op == "gt")
                {
                    final switch (shape)
                    {
                        case BranchShape.NEXT0:
                        jle32Ref(as, vm, block, target1, 1);
                        break;

                        case BranchShape.NEXT1:
                        jg32Ref(as, vm, block, target0, 0);
                        break;

                        case BranchShape.DEFAULT:
                        jg32Ref(as, vm, block, target0, 0);
                        jmp32Ref(as, vm, block, target1, 1);
                    }
                }
                else if (op == "ge")
                {
                    final switch (shape)
                    {
                        case BranchShape.NEXT0:
                        jl32Ref(as, vm, block, target1, 1);
                        break;

                        case BranchShape.NEXT1:
                        jge32Ref(as, vm, block, target0, 0);
                        break;

                        case BranchShape.DEFAULT:
                        jge32Ref(as, vm, block, target0, 0);
                        jmp32Ref(as, vm, block, target1, 1);
                    }
                }

                // Floating-point comparisons
                else if (op == "feq")
                {
                    // feq:
                    // True: 100
                    // False: 111 or 000 or 001
                    // False: JNE + JP
                    jne32Ref(as, vm, block, target1, 1);
                    jp32Ref(as, vm, block, target1, 1);
                    jmp32Ref(as, vm, block, target0, 0);
                }
                else if (op == "fne")
                {
                    // fne: 
                    // True: 111 or 000 or 001
                    // False: 100
                    // True: JNE + JP
                    jne32Ref(as, vm, block, target0, 0);
                    jp32Ref(as, vm, block, target0, 0);
                    jmp32Ref(as, vm, block, target1, 1);
                }
                else if (op == "flt")
                {
                    ja32Ref(as, vm, block, target0, 0);
                    jmp32Ref(as, vm, block, target1, 1);
                }
                else if (op == "fle")
                {
                    jae32Ref(as, vm, block, target0, 0);
                    jmp32Ref(as, vm, block, target1, 1);
                }
                else if (op == "fgt")
                {
                    ja32Ref(as, vm, block, target0, 0);
                    jmp32Ref(as, vm, block, target1, 1);
                }
                else if (op == "fge")
                {
                    jae32Ref(as, vm, block, target0, 0);
                    jmp32Ref(as, vm, block, target1, 1);
                }
            }
        );
    }
}

alias gen_eq_i8 = CmpOp!("eq", 8);
alias gen_eq_i32 = CmpOp!("eq", 32);
alias gen_ne_i32 = CmpOp!("ne", 32);
alias gen_lt_i32 = CmpOp!("lt", 32);
alias gen_le_i32 = CmpOp!("le", 32);
alias gen_gt_i32 = CmpOp!("gt", 32);
alias gen_ge_i32 = CmpOp!("ge", 32);
alias gen_eq_i64 = CmpOp!("eq", 64);

alias gen_eq_bool = CmpOp!("eq", 8);
alias gen_ne_bool = CmpOp!("ne", 8);
alias gen_eq_refptr = CmpOp!("eq", 64);
alias gen_ne_refptr = CmpOp!("ne", 64);
alias gen_eq_rawptr = CmpOp!("eq", 64);
alias gen_ne_rawptr = CmpOp!("ne", 64);
alias gen_eq_f64 = CmpOp!("feq", 64);
alias gen_ne_f64 = CmpOp!("fne", 64);
alias gen_lt_f64 = CmpOp!("flt", 64);
alias gen_le_f64 = CmpOp!("fle", 64);
alias gen_gt_f64 = CmpOp!("fgt", 64);
alias gen_ge_f64 = CmpOp!("fge", 64);

void gen_if_true(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // If a boolean argument immediately precedes, the
    // conditional branch has already been generated
    if (boolArgPrev(instr) is true)
        return;

    // Compare the argument to the true boolean value
    auto argOpnd = ctx.getWordOpnd(as, instr, 0, 8, scrRegs[0].opnd(8));
    as.cmp(argOpnd, X86Opnd(TRUE.word.int8Val));

    auto branchT = getBranchEdge(instr.getTarget(0), ctx, false);
    auto branchF = getBranchEdge(instr.getTarget(1), ctx, false);

    // Generate the branch code
    ver.genBranch(
        as,
        branchT,
        branchF,
        delegate void(
            CodeBlock as,
            BlockVersion block,
            CodeFragment target0,
            CodeFragment target1,
            BranchShape shape
        )
        {
            final switch (shape)
            {
                case BranchShape.NEXT0:
                jne32Ref(as, vm, block, target1, 1);
                break;

                case BranchShape.NEXT1:
                je32Ref(as, vm, block, target0, 0);
                break;

                case BranchShape.DEFAULT:
                je32Ref(as, vm, block, target0, 0);
                jmp32Ref(as, vm, block, target1, 1);
            }
        }
    );
}

void JumpOp(size_t succIdx)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto branch = getBranchEdge(
        instr.getTarget(succIdx),
        ctx,
        true
    );

    // Jump to the target block directly
    ver.genBranch(
        as,
        branch,
        null,
        delegate void(
            CodeBlock as,
            BlockVersion block,
            CodeFragment target0,
            CodeFragment target1,
            BranchShape shape
        )
        {
            final switch (shape)
            {
                case BranchShape.NEXT0:
                break;

                case BranchShape.NEXT1:
                assert (false);

                case BranchShape.DEFAULT:
                jmp32Ref(as, vm, block, target0, 0);
            }
        }
    );
}

alias gen_jump = JumpOp!(0);
alias gen_jump_false = JumpOp!(1);

/**
Throw an exception and unwind the stack when one calls a non-function.
Returns a pointer to an exception handler.
*/
extern (C) CodePtr throwCallExc(IRInstr instr, BranchCode excHandler)
{
    auto fnName = getCalleeName(instr);

    return throwError(
        instr,
        excHandler,
        "TypeError",
        fnName?
        ("call to non-function \"" ~ fnName ~ "\""):
        ("call to non-function")
    );
}

/**
Generate the final branch and exception handler for a call instruction
*/
void genCallBranch(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr callInstr,
    CodeBlock as,
    BranchGenFn genFn,
    IRFunction callee,
    bool mayThrow
)
{
    // If the callee is known (if this is a direct call)
    if (callee)
    {
        // Register this call site on the callee
        callee.callSites[ver] = ver;
    }

    // Remove information about values dead after the call
    ctx.removeDead(
        delegate bool(LiveInfo liveInfo, IRDstValue value)
        {
            return liveInfo.liveAfter(value, callInstr);
        }
    );

    // Map the return value tag to a register
    ctx.mapToStack(callInstr);

    // Map the return value to the return word register
    ctx.mapToReg(retWordReg, callInstr, 64);

    BranchCode excBranch = null;

    // Create the exception branch object
    if (callInstr.getTarget(1))
    {
        excBranch = getBranchEdge(
            callInstr.getTarget(1),
            ctx,
            false,
            delegate void(CodeBlock as)
            {
                // Pop the exception word off the stack and
                // move it into the return word register
                as.add(wspReg, Word.sizeof);
                as.getWord(retWordReg, -1);

                // Pop the exception tag of the stack and move it to
                // the instruction's output slot on the type stack
                as.add(tspReg, Tag.sizeof);
                as.getTag(retTagReg.reg(8), -1);
                as.setTag(callInstr.outSlot, retTagReg.opnd(8));
            }
        );
    }

    // Create a call continuation stub
    auto contStub = getContStub(ver, excBranch, ctx, callee);

    // If the call may throw an exception
    if (mayThrow)
    {
        as.jmp(Label.SKIP);

        as.label(Label.THROW);

        as.saveJITRegs();

        // Throw the call exception, unwind the stack,
        // find the topmost exception handler
        as.ptr(cargRegs[0], callInstr);
        as.ptr(cargRegs[1], excBranch);
        as.ptr(scrRegs[0], &throwCallExc);
        as.call(scrRegs[0].opnd);

        as.loadJITRegs();

        // Jump to the exception handler
        as.jmp(X86Opnd(RAX));

        as.label(Label.SKIP);
    }

    // Generate the call's final branch code
    ver.genBranch(
        as,
        contStub,
        excBranch,
        genFn
    );

    //writeln("call block length: ", ver.length);
}

void gen_call_prim(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // Function name string (D string)
    auto strArg = cast(IRString)instr.getArg(0);
    assert (strArg !is null);
    auto nameStr = strArg.str;

    // Increment the stat counter for this primitive
    as.incStatCnt(stats.getPrimCallCtr(to!string(nameStr)), scrRegs[0]);

    // Get the primitve function from the global object
    auto closVal = getProp(vm.globalObj, nameStr);
    assert (
        closVal.tag is Tag.CLOSURE,
        "failed to resolve closure in call_prim"
    );
    assert (closVal.word.ptrVal !is null);
    auto fun = getFunPtr(closVal.word.ptrVal);

    //as.printStr(to!string(nameStr));

    // Check that the argument count matches
    auto numArgs = cast(int32_t)instr.numVarArgs;
    assert (
        numArgs is fun.numParams,
        "incorrect argument count for call to primitive " ~ fun.getName
    );

    // Check that the hidden arguments are not used
    assert (
        (!fun.closVal || fun.closVal.hasNoUses) &&
        (!fun.thisVal || fun.thisVal.hasNoUses) &&
        (!fun.argcVal || fun.argcVal.hasNoUses),
        "call_prim: hidden args used"
    );

    // If the function is not yet compiled, compile it now
    if (fun.entryBlock is null)
    {
        //writeln(core.memory.GC.addrOf(cast(void*)fun.ast));
        astToIR(fun.ast, fun);
    }

    // Get the argument value type
    auto argTypes = new ValType[fun.numParams];
    for (size_t argIdx = 0; argIdx < numArgs; ++argIdx)
        argTypes[argIdx] = ctx.getType(instr.getArg(1 + argIdx));

    // Create a context taking into account the argument types
    auto entrySt = new CodeGenCtx(
        fun,
        ValType(),
        argTypes,
        true
    );

    // Request an instance for the function entry block
    auto entryVer = getBlockVersion(fun.entryBlock, entrySt);

    // List of argument moves
    Move[] argMoves;
    argMoves.reserve(numArgs);

    //writeln();

    // For each visible argument
    for (size_t i = 0; i < numArgs; ++i)
    {
        auto instrArgIdx = 1 + i;
        auto dstIdx = -numArgs + cast(int32_t)i;

        auto argVal = instr.getArg(instrArgIdx);

        auto paramVal = fun.paramVals[i];

        // Get the value state for this parameter
        auto paramSt = entryVer.ctx.getState(paramVal);

        // Get the destination operand
        auto dstOpnd = paramSt.isReg? argRegs[i].opnd:wordStackOpnd(dstIdx);

        // If the argument is a string constant
        if (auto argStr = cast(IRString)argVal)
        {
            argMoves.assumeSafeAppend ~= Move(dstOpnd, argStr);
        }
        else
        {
            auto argOpnd = ctx.getWordOpnd(argVal, 64);
            argMoves.assumeSafeAppend ~= Move(dstOpnd, argOpnd);
        }

        // If the entry context knows the type tag
        if (paramSt.tagKnown)
            continue;

        // Copy the argument type
        auto tagOpnd = ctx.getTagOpnd(
            as,
            instr,
            instrArgIdx,
            scrRegs[1].opnd(8),
            true
        );
        as.setTag(dstIdx, tagOpnd);
    }

    // TODO: argc propagation
    // Write the argument count
    as.setWord(-numArgs - 1, numArgs);

    // Spill the values that are live after the call
    ctx.spillLiveAfter(as, instr);

    /*
    writeln("executing arg moves");
    writeln("argMoves.length=", argMoves.length);
    foreach (move; argMoves)
        writeln(move.dst, " <= ", move.src);
    writeln();
    */

    // Execute the argument moves
    as.execMoves(argMoves, scrRegs[0], scrRegs[1]);

    // Push space for the callee arguments and locals
    as.sub(X86Opnd(tspReg), X86Opnd(fun.numLocals));
    as.sub(X86Opnd(wspReg), X86Opnd(8 * fun.numLocals));

    ver.genCallBranch(
        ctx,
        instr,
        as,
        delegate void(
            CodeBlock as,
            BlockVersion block,
            CodeFragment target0,
            CodeFragment target1,
            BranchShape shape
        )
        {
            // Get the return address slot of the callee
            auto raSlot = entryVer.block.fun.raVal.outSlot;
            assert (raSlot !is NULL_STACK);

            // Place the return address in the return address register
            as.movAbsRef(vm, raReg, block, target0, 0);

            // Jump to the function entry block
            jmp32Ref(as, vm, block, entryVer, 0);
        },
        fun,
        false
    );
}

void gen_call(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    //
    // Function pointer extraction
    //

    // Get the type information for the closure value
    auto closType = ctx.getType(instr.getArg(0)).propType();

    // This may throw an exception if the callee is not a closure
    auto mayThrow = !closType.tagKnown || closType.tag !is Tag.CLOSURE;

    // Get the number of arguments supplied
    auto numArgs = cast(uint32_t)instr.numVarArgs;

    // If the callee function is known
    if (closType.fptrKnown)
    {
        as.incStatCnt(&stats.numCallFast, scrRegs[0]);

        // Get the function pointer
        IRFunction fun = closType.fptr;

        // If the function is not yet compiled, compile it now
        if (fun.entryBlock is null)
        {
            try
            {
                astToIR(fun.ast, fun);
            }

            catch (Error err)
            {
                assert (
                    false,
                    "failed to generate IR for: \"" ~ fun.getName ~ "\"\n" ~
                    err.toString
                );
            }
        }

        // Compute the number of missing arguments
        auto numMissing = (fun.numParams > numArgs)? (fun.numParams - numArgs):0;

        // Compute the actual number of extra arguments
        auto numExtra = (numArgs > fun.numParams)? (numArgs - fun.numParams):0;

        // Compute the number of arguments we actually need to pass
        auto numPassed = numArgs + numMissing;

        // Compute the number of locals in this frame
        auto frameSize = fun.numLocals + numExtra;

        // Get the argument value type
        auto argTypes = new ValType[fun.numParams];
        for (size_t argIdx = 0; argIdx < argTypes.length; ++argIdx)
        {
            if (argIdx < numArgs)
                argTypes[argIdx] = ctx.getType(instr.getArg(2 + argIdx));
            else
                argTypes[argIdx] = ValType(UNDEF);
        }

        // Create a context taking into account the argument types
        auto entrySt = new CodeGenCtx(
            fun,
            ctx.getType(instr.getArg(1)),
            argTypes,
            (numArgs == fun.numParams)
        );

        // Request an instance for the function entry block
        auto entryVer = getBlockVersion(fun.entryBlock, entrySt);

        // List of argument moves
        Move[] argMoves;
        argMoves.reserve(numArgs);

        // Copy the function arguments supplied
        for (int32_t i = 0; i < numArgs; ++i)
        {
            auto instrArgIdx = 2 + i;
            auto dstIdx = -(numPassed - i);

            auto argVal = instr.getArg(instrArgIdx);

            auto paramVal = (i < fun.numParams)? fun.paramVals[i]:null;

            // Get the value state for this parameter
            auto paramSt = paramVal? entryVer.ctx.getState(paramVal):ValState();

            // If the parameter is unused, skip it
            if (paramVal && paramVal.hasNoUses && !fun.usesVarArg)
                continue;

            // Get the destination operand
            auto dstOpnd = paramSt.isReg? argRegs[i].opnd:wordStackOpnd(dstIdx);

            // If the argument is a string constant
            if (auto argStr = cast(IRString)argVal)
            {
                argMoves.assumeSafeAppend ~= Move(dstOpnd, argStr);
            }
            else
            {
                auto argOpnd = ctx.getWordOpnd(argVal, 64);
                argMoves.assumeSafeAppend ~= Move(dstOpnd, argOpnd);
            }

            // If the entry context knows the type tag, skip this
            if (paramVal && paramSt.tagKnown && !fun.usesVarArg)
                continue;

            // Copy the argument type
            auto tagOpnd = ctx.getTagOpnd(
                as,
                instr,
                instrArgIdx,
                scrRegs[0].opnd(8),
                true
            );
            as.setTag(dstIdx, tagOpnd);
        }

        // Write undefined values for the missing arguments
        for (int32_t i = 0; i < numMissing; ++i)
        {
            auto dstIdx = -(i + 1);
            auto paramIdx = fun.numParams-1-i;

            // Set the argument value to  undefined
            auto paramVal = fun.paramVals[paramIdx];
            auto paramSt = entryVer.ctx.getState(paramVal);
            auto dstOpnd = paramSt.isReg? argRegs[paramIdx].opnd:wordStackOpnd(dstIdx);

            auto argOpnd = X86Opnd(UNDEF.word.int8Val);
            argMoves.assumeSafeAppend ~= Move(dstOpnd, argOpnd);

            // Set the type tag
            as.setTag(dstIdx, UNDEF.tag);
        }

        // Write the argument count
        as.setWord(-numPassed - 1, numArgs);

        // Write the "this" argument
        if (fun.thisVal.hasUses)
        {
            auto thisReg = ctx.getWordOpnd(
                as,
                instr,
                1,
                64,
                scrRegs[0].opnd(64),
                true,
                false
            );
            as.setWord(-numPassed - 2, thisReg);

            // If the entry context doesn't know the type tag
            if (!entryVer.ctx.getType(fun.thisVal).tagKnown)
            {
                auto tagOpnd = ctx.getTagOpnd(
                    as,
                    instr,
                    1,
                    scrRegs[0].opnd(8),
                    true
                );
                as.setTag(-numPassed - 2, tagOpnd);
            }
        }

        // Write the closure argument
        if (fun.closVal.hasUses)
        {
            auto closReg = ctx.getWordOpnd(
                as,
                instr,
                0,
                64,
                scrRegs[0].opnd(64),
                false,
                false
            );
            as.setWord(-numPassed - 3, closReg);
        }

        // Spill the values that are live after the call
        ctx.spillLiveAfter(as, instr);

        // Execute the argument moves
        as.execMoves(argMoves, scrRegs[1], scrRegs[2]);

        // Push space for the callee arguments and locals
        as.sub(X86Opnd(tspReg), X86Opnd(frameSize));
        as.sub(X86Opnd(wspReg), X86Opnd(8 * frameSize));

        ver.genCallBranch(
            ctx,
            instr,
            as,
            delegate void(
                CodeBlock as,
                BlockVersion block,
                CodeFragment target0,
                CodeFragment target1,
                BranchShape shape
            )
            {
                // Place the return address in the return address register
                as.movAbsRef(vm, raReg, block, target0, 0);

                // Jump to the function entry block
                jmp32Ref(as, vm, block, entryVer, 0);
            },
            fun,
            false
        );

        return;
    }

    as.incStatCnt(&stats.numCallSlow, scrRegs[0]);

    // If an exception may be thrown
    if (mayThrow && !opts.load_tag_tests)
    {
        // Get the type tag for the closure value
        auto closTag = ctx.getTagOpnd(
            as,
            instr,
            0,
            scrRegs[1].opnd(8),
            false
        );

        // If the value is not a closure, bailout
        as.incStatCnt(stats.getTagTestCtr("is_closure"), scrRegs[2]);
        as.cmp(closTag, X86Opnd(Tag.CLOSURE));
        as.jne(Label.THROW);
    }

    // Free an extra register to use as scratch
    auto scrReg3 = ctx.freeReg(as, instr);

    // Get the closure pointer in a register
    auto closReg = ctx.getWordOpnd(
        as,
        instr,
        0,
        64,
        scrRegs[0].opnd(64),
        false,
        false
    );
    assert (closReg.isGPR);

    // Get the IRFunction pointer from the closure object
    auto fptrMem = X86Opnd(64, closReg.reg, FPTR_SLOT_OFS);
    as.mov(scrRegs[1].opnd(64), fptrMem);

    // Compute -missingArgs = numArgs - numParams
    // This is the negation of the number of missing arguments
    // We use this as an offset when writing arguments to the stack
    auto numParamsOpnd = memberOpnd!("IRFunction.numParams")(scrRegs[1]);
    as.mov(scrRegs[2].opnd(32), X86Opnd(numArgs));
    as.sub(scrRegs[2].opnd(32), numParamsOpnd);
    as.cmp(scrRegs[2].opnd(32), X86Opnd(0));
    as.jle(Label.FALSE);
    as.xor(scrRegs[2].opnd(32), scrRegs[2].opnd(32));
    as.label(Label.FALSE);
    as.movsx(scrRegs[2].opnd(64), scrRegs[2].opnd(32));

    // Initialize the missing arguments, if any
    as.mov(scrReg3.opnd(64), scrRegs[2].opnd(64));
    as.label(Label.LOOP);
    as.cmp(scrReg3.opnd(64), X86Opnd(0));
    as.jge(Label.LOOP_EXIT);
    as.mov(X86Opnd(64, wspReg, 0, 8, scrReg3), X86Opnd(UNDEF.word.int8Val));
    as.mov(X86Opnd(8, tspReg, 0, 1, scrReg3), X86Opnd(UNDEF.tag));
    as.add(scrReg3.opnd(64), X86Opnd(1));
    as.jmp(Label.LOOP);
    as.label(Label.LOOP_EXIT);

    static void movArgWord(CodeBlock as, size_t argIdx, X86Opnd val)
    {
        as.mov(X86Opnd(64, wspReg, -8 * cast(int32_t)(argIdx+1), 8, scrRegs[2]), val);
    }

    static void movArgTag(CodeBlock as, size_t argIdx, X86Opnd val)
    {
        as.mov(X86Opnd(8, tspReg, -1 * cast(int32_t)(argIdx+1), 1, scrRegs[2]), val);
    }

    // Copy the function arguments in reverse order
    for (size_t i = 0; i < numArgs; ++i)
    {
        auto instrArgIdx = instr.numArgs - (1+i);

        // Copy the argument word
        auto argOpnd = ctx.getWordOpnd(
            as,
            instr,
            instrArgIdx,
            64,
            scrReg3.opnd(64),
            true,
            false
        );
        movArgWord(as, i, argOpnd);

        // Copy the argument type
        auto tagOpnd = ctx.getTagOpnd(
            as,
            instr,
            instrArgIdx,
            scrReg3.opnd(8),
            true
        );
        movArgTag(as, i, tagOpnd);
    }

    // Write the argument count
    movArgWord(as, numArgs + 0, X86Opnd(numArgs));

    // Write the "this" argument
    auto thisReg = ctx.getWordOpnd(
        as,
        instr,
        1,
        64,
        scrReg3.opnd(64),
        true,
        false
    );
    movArgWord(as, numArgs + 1, thisReg);
    auto tagOpnd = ctx.getTagOpnd(
        as,
        instr,
        1,
        scrReg3.opnd(8),
        true
    );
    movArgTag(as, numArgs + 1, tagOpnd);

    // Write the closure argument
    movArgWord(as, numArgs + 2, closReg);

    // Compute the total number of locals and extra arguments
    // input : scr1, IRFunction
    // output: scr0, total frame size
    // mangle: scr3
    // scr3 = numArgs, actual number of args passed
    as.mov(scrReg3.opnd(32), X86Opnd(numArgs));
    // scr3 = numArgs - numParams (num extra args)
    as.sub(scrReg3.opnd(32), numParamsOpnd);
    // scr0 = numLocals
    as.getMember!("IRFunction.numLocals")(scrRegs[0].reg(32), scrRegs[1]);
    // if there are no missing parameters, skip the add
    as.cmp(scrReg3.opnd(32), X86Opnd(0));
    as.jle(Label.FALSE2);
    // src0 = numLocals + extraArgs
    as.add(scrRegs[0].opnd(32), scrReg3.opnd(32));
    as.label(Label.FALSE2);

    // Spill the values that are live after the call
    ctx.spillLiveAfter(as, instr);

    ver.genCallBranch(
        ctx,
        instr,
        as,
        delegate void(
            CodeBlock as,
            BlockVersion block,
            CodeFragment target0,
            CodeFragment target1,
            BranchShape shape
        )
        {
            // Pass the return address in the return address register
            as.movAbsRef(vm, raReg, block, target0, 0);

            // Adjust the stack pointers
            as.sub(X86Opnd(tspReg), scrRegs[0].opnd(64));

            // Adjust the word stack pointer
            as.shl(scrRegs[0].opnd(64), X86Opnd(3));
            as.sub(X86Opnd(wspReg), scrRegs[0].opnd(64));

            // Jump to the function entry block
            as.jmp(memberOpnd!("IRFunction.entryCode")(scrRegs[1]));
        },
        null,
        mayThrow
    );
}

void gen_call_apply(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) CodePtr op_call_apply(IRInstr instr, CodePtr retAddr)
    {
        // Increment the number of calls performed using apply
        stats.numCallApply++;

        vm.setCurInstr(instr);

        auto closVal = vm.getArgVal(instr, 0);
        auto thisVal = vm.getArgVal(instr, 1);
        auto tblVal  = vm.getArgVal(instr, 2);
        auto argcVal = vm.getArgUint32(instr, 3);

        assert (
            tblVal.tag !is Tag.ARRAY,
            "invalid argument table"
        );

        assert (
            closVal.tag is Tag.CLOSURE,
            "apply call on to non-function"
        );

        // Get the function object from the closure
        auto closPtr = closVal.word.ptrVal;
        auto fun = getFunPtr(closPtr);

        // Get the array table pointer
        auto tblPtr = tblVal.word.ptrVal;

        auto argVals = cast(ValuePair*)GC.malloc(ValuePair.sizeof * argcVal);

        // Fetch the argument values from the array table
        for (uint32_t i = 0; i < argcVal; ++i)
        {
            argVals[i].word.uint64Val = arrtbl_get_word(tblPtr, i);
            argVals[i].tag = cast(Tag)arrtbl_get_tag(tblPtr, i);
        }

        // Prepare the callee stack frame
        vm.callFun(
            fun,
            retAddr,
            closPtr,
            thisVal,
            argcVal,
            argVals
        );

        GC.free(argVals);

        vm.setCurInstr(null);

        // Return the function entry point code
        return fun.entryCode;
    }

    // Spill the values that are live before the call
    ctx.spillLiveBefore(as, instr);

    ver.genCallBranch(
        ctx,
        instr,
        as,
        delegate void(
            CodeBlock as,
            BlockVersion block,
            CodeFragment target0,
            CodeFragment target1,
            BranchShape shape
        )
        {
            as.saveJITRegs();

            // Pass the instruction as an argument
            as.ptr(cargRegs[0], instr);

            // Pass the return address as third argument
            as.movAbsRef(vm, cargRegs[1], block, target0, 0);

            // Call the host function
            as.ptr(scrRegs[0], &op_call_apply);
            as.call(scrRegs[0]);

            as.loadJITRegs();

            // Pass the return address in the return address register
            as.movAbsRef(vm, raReg, block, target0, 0);

            // Jump to the address returned by the host function
            as.jmp(cretReg.opnd);
        },
        null,
        false
    );
}

void gen_load_file(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) CodePtr op_load_file(
        IRInstr instr,
        CodeFragment retTarget,
        CodeFragment excTarget
    )
    {
        // Stop recording execution time, start recording compilation time
        stats.execTimeStop();
        stats.compTimeStart();

        // When exiting this function
        scope (exit)
        {
            // Stop recording compilation time, resume recording execution time
            stats.compTimeStop();
            stats.execTimeStart();
        }

        auto strPtr = vm.getArgStr(instr, 0);
        auto fileName = vm.getLoadPath(extractStr(strPtr));

        try
        {
            // Parse the source file and generate IR
            auto ast = parseFile(fileName);
            auto fun = astToIR(ast);

            // Create a GC root for the function to prevent it from
            // being collected if the GC runs during its compilation
            auto funPtr = GCRoot(Word.funv(fun), Tag.FUNPTR);

            // Create a version instance object for the unit function entry
            auto entryInst = getBlockVersion(
                fun.entryBlock,
                new CodeGenCtx(fun)
            );

            // Compile the unit entry version
            vm.compile(instr);

            // Get the return address for the continuation target
            auto retAddr = retTarget.getCodePtr(vm.execHeap);

            // Prepare the callee stack frame
            vm.callFun(
                fun,
                retAddr,
                null,
                vm.globalObj,
                0,
                null
            );

            // Return the function entry point code
            return entryInst.getCodePtr(vm.execHeap);
        }

        catch (Exception err)
        {
            return throwError(
                instr,
                excTarget,
                "ReferenceError",
                "failed to load unit \"" ~ to!string(fileName) ~ "\""
            );
        }

        catch (Error err)
        {
            return throwError(
                instr,
                excTarget,
                "SyntaxError",
                err.toString
            );
        }
    }

    // Spill the values that are live before the call
    ctx.spillLiveBefore(as, instr);

    ver.genCallBranch(
        ctx,
        instr,
        as,
        delegate void(
            CodeBlock as,
            BlockVersion block,
            CodeFragment target0,
            CodeFragment target1,
            BranchShape shape
        )
        {
            as.saveJITRegs();

            // Pass the instruction as an argument
            as.ptr(cargRegs[0], instr);

            // Pass the return and exception targets as third arguments
            as.ptr(cargRegs[1], target0);
            as.ptr(cargRegs[2], target1);

            // Call the host function
            as.ptr(scrRegs[0], &op_load_file);
            as.call(scrRegs[0]);

            as.loadJITRegs();

            // Pass the return address in the return address register
            as.movAbsRef(vm, raReg, block, target0, 0);

            // Jump to the address returned by the host function
            as.jmp(cretReg.opnd);
        },
        null,
        false
    );
}

void gen_eval_str(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) CodePtr op_eval_str(
        IRInstr instr,
        CodeFragment retTarget,
        CodeFragment excTarget
    )
    {
        // Stop recording execution time, start recording compilation time
        stats.execTimeStop();
        stats.compTimeStart();

        // When exiting this function
        scope (exit)
        {
            // Stop recording compilation time, resume recording execution time
            stats.compTimeStop();
            stats.execTimeStart();
        }

        auto strPtr = vm.getArgStr(instr, 0);
        auto codeStr = extractStr(strPtr);

        try
        {
            // Parse the source file and generate IR
            auto ast = parseString(codeStr, "eval_str");
            auto fun = astToIR(ast);

            // Create a GC root for the function to prevent it from
            // being collected if the GC runs during its compilation
            auto funPtr = GCRoot(Word.funv(fun), Tag.FUNPTR);

            // Create a version instance object for the unit function entry
            auto entryInst = getBlockVersion(
                fun.entryBlock,
                new CodeGenCtx(fun)
            );

            // Compile the unit entry version
            vm.compile(instr);

            // Get the return address for the continuation target
            auto retAddr = retTarget.getCodePtr(vm.execHeap);

            // Prepare the callee stack frame
            vm.callFun(
                fun,
                retAddr,
                null,
                vm.globalObj,
                0,
                null
            );

            // Return the function entry point code
            return entryInst.getCodePtr(vm.execHeap);
        }

        catch (Error err)
        {
            return throwError(
                instr,
                excTarget,
                "SyntaxError",
                err.toString
            );
        }
    }

    // Spill the values that are live before the call
    ctx.spillLiveBefore(as, instr);

    ver.genCallBranch(
        ctx,
        instr,
        as,
        delegate void(
            CodeBlock as,
            BlockVersion block,
            CodeFragment target0,
            CodeFragment target1,
            BranchShape shape
        )
        {
            as.saveJITRegs();

            // Pass the instruction as an argument
            as.ptr(cargRegs[0], instr);

            // Pass the return and exception targets
            as.ptr(cargRegs[1], target0);
            as.ptr(cargRegs[2], target1);

            // Call the host function
            as.ptr(scrRegs[0], &op_eval_str);
            as.call(scrRegs[0]);

            as.loadJITRegs();

            // Pass the return address in the return address register
            as.movAbsRef(vm, raReg, block, target0, 0);

            // Jump to the address returned by the host function
            as.jmp(cretReg.opnd);
        },
        null,
        false
    );
}

void gen_ret(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto fun = instr.block.fun;

    auto argcSlot  = fun.argcVal.outSlot;
    auto numParams = fun.numParams;
    auto numLocals = fun.numLocals;

    // Get type information about the return value
    auto retType = ctx.getType(instr.getArg(0)).propType;

    // If there is only one caller (return not yet executed)
    if (fun.numRets is 0)
    {
        fun.retType = retType;
    }
    else
    {
        // If this is not a subtype of the function's known return type
        if (!retType.isSubType(fun.retType))
        {
            // Invalidate call continuations
            removeConts(fun);

            // Update the known return type
            fun.retType = fun.retType.join(retType);
        }
    }

    // Increment the number of returns compiled
    fun.numRets++;

    // Get the return value word operand
    auto retOpnd = ctx.getWordOpnd(
        as,
        instr,
        0,
        64,
        retWordReg.opnd(64),
        true,
        false
    );

    // Get the return value type operand
    auto tagOpnd = ctx.getTagOpnd(
        as,
        instr,
        0,
        (retOpnd != retTagReg.opnd(64))?
            retTagReg.opnd(8):
            scrRegs[1].opnd(8),
        true
    );

    // Get the return address operand
    auto raOpnd = ctx.getWordOpnd(fun.raVal, 64);

    //as.printStr("ret from " ~ fun.getName);

    // Move the return word and tag to the return registers
    if (retWordReg.opnd != retOpnd)
        as.mov(retWordReg.opnd, retOpnd);
    if (retTagReg.opnd(8) != tagOpnd)
        as.mov(retTagReg.opnd(8), tagOpnd);

    //writeln("argcMatch=", ctx.argcMatch);

    // If this is a runtime primitive function
    if (fun.isPrim || ctx.argcMatch)
    {
        // Get the return address into a register
        if (!raOpnd.isReg)
        {
            as.mov(scrRegs[1].opnd, raOpnd);
            raOpnd = scrRegs[1].opnd;
        }

        // Pop all local stack slots
        as.add(tspReg.opnd(64), X86Opnd(Tag.sizeof * numLocals));
        as.add(wspReg.opnd(64), X86Opnd(Word.sizeof * numLocals));
    }
    else
    {
        //as.printStr("argc=");
        //as.printInt(scrRegs[0].opnd(64));

        // Compute the number of extra arguments into r0
        as.getWord(scrRegs[0].reg(32), argcSlot);
        if (numParams !is 0)
            as.sub(scrRegs[0].opnd(32), X86Opnd(numParams));
        as.xor(scrRegs[1].opnd(32), scrRegs[1].opnd(32));
        as.cmp(scrRegs[0].opnd(32), X86Opnd(0));
        as.cmovl(scrRegs[0].reg(32), scrRegs[1].opnd(32));

        // Compute the total number of stack slots to pop into r0
        as.add(scrRegs[0].opnd(32), X86Opnd(numLocals));

        // Get the return address into a register
        if (!raOpnd.isReg)
        {
            as.mov(scrRegs[1].opnd, raOpnd);
            raOpnd = scrRegs[1].opnd;
        }

        // Pop all local stack slots and arguments
        //as.printStr("popping");
        //as.printUint(scrRegs[0].opnd);
        as.add(tspReg.opnd(64), scrRegs[0].opnd);
        as.shl(scrRegs[0].opnd, X86Opnd(3));
        as.add(wspReg.opnd(64), scrRegs[0].opnd);
    }

    // Jump to the return address
    as.jmp(raOpnd);

    // Mark the end of the fragment
    ver.markEnd(as);
}

void gen_throw(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // Get the string pointer
    auto excWordOpnd = ctx.getWordOpnd(as, instr, 0, 64, X86Opnd.NONE, true, false);
    auto excTypeOpnd = ctx.getTagOpnd(as, instr, 0, X86Opnd.NONE, true);

    // Spill the values live before the instruction
    ctx.spillValues(
        as,
        delegate bool(LiveInfo liveInfo, IRDstValue value)
        {
            return liveInfo.liveBefore(value, instr);
        }
    );

    as.saveJITRegs();

    // Call the host throwExc function
    as.ptr(cargRegs[0], instr);
    as.mov(cargRegs[1].opnd, X86Opnd(0));
    as.mov(cargRegs[2].opnd, excWordOpnd);
    as.mov(cargRegs[3].opnd(8), excTypeOpnd);
    as.ptr(scrRegs[0], &throwExc);
    as.call(scrRegs[0]);

    as.loadJITRegs();

    // Jump to the exception handler
    as.jmp(cretReg.opnd);

    // Mark the end of the fragment
    ver.markEnd(as);
}

void gen_catch(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto wordOpnd = ctx.getWordOpnd(as, instr, 0, 64, scrRegs[0].opnd(64), true);
    auto outOpnd = ctx.getOutOpnd(as, instr, 64, true);
    if (outOpnd != wordOpnd)
        as.mov(outOpnd, wordOpnd);

    auto tagOpnd = ctx.getTagOpnd(as, instr, 0, scrRegs[0].opnd(8), true);
    ctx.setOutTag(as, instr, tagOpnd.reg);
}

void GetValOp(Tag tag, string fName)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto fSize = 8 * mixin("VM." ~ fName ~ ".sizeof");

    auto outOpnd = ctx.getOutOpnd(as, instr, fSize);
    assert (outOpnd.isReg);

    as.ptr(scrRegs[0], vm);
    as.getMember!("VM." ~ fName)(outOpnd.reg, scrRegs[0]);

    ctx.setOutTag(as, instr, tag);
}

alias gen_get_obj_proto = GetValOp!(Tag.OBJECT, "objProto.word");
alias gen_get_arr_proto = GetValOp!(Tag.OBJECT, "arrProto.word");
alias gen_get_fun_proto = GetValOp!(Tag.OBJECT, "funProto.word");
alias gen_get_str_proto = GetValOp!(Tag.OBJECT, "strProto.word");
alias gen_get_global_obj = GetValOp!(Tag.OBJECT, "globalObj.word");
alias gen_get_heap_size = GetValOp!(Tag.INT32, "heapSize");
alias gen_get_gc_count = GetValOp!(Tag.INT32, "gcCount");

void gen_get_heap_free(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto outOpnd = ctx.getOutOpnd(as, instr, 32);

    as.ptr(scrRegs[1], vm);
    as.getMember!("VM.allocPtr")(scrRegs[0], scrRegs[1]);
    as.getMember!("VM.heapLimit")(scrRegs[1], scrRegs[1]);

    as.sub(scrRegs[1].opnd, scrRegs[0].opnd);

    as.mov(outOpnd, scrRegs[1].opnd(32));

    ctx.setOutTag(as, instr, Tag.INT32);
}

void HeapAllocOp(Tag tag)(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static refptr allocFallback(
        IRInstr curInstr,
        uint32_t allocSize
    )
    {
        vm.setCurInstr(curInstr);

        //writeln("alloc fallback");

        auto ptr = heapAlloc(vm, allocSize);

        vm.setCurInstr(null);

        return ptr;
    }

    // Spill the values live before the instruction
    ctx.spillValues(
        as,
        delegate bool(LiveInfo liveInfo, IRDstValue value)
        {
            return liveInfo.liveBefore(value, instr);
        }
    );

    as.incStatCnt(&stats.numHeapAllocs, scrRegs[0]);

    // Get the allocation size operand
    auto szOpnd = ctx.getWordOpnd(as, instr, 0, 32, X86Opnd.NONE, true, false);

    // Get the output operand
    auto outOpnd = ctx.getOutOpnd(as, instr, 64);
    assert (outOpnd.isReg);

    // r0 = vm
    as.ptr(scrRegs[0], vm);

    // The output of this instruction is the current allocPtr
    // out = allocPtr
    as.getMember!("VM.allocPtr")(outOpnd.reg, scrRegs[0]);

    // r1 = allocPtr + size
    // Note: we zero extend the size operand to 64-bits
    as.mov(scrRegs[1].opnd(32), szOpnd);
    as.add(scrRegs[1].opnd(64), outOpnd);

    // r2 = heapLimit
    as.getMember!("VM.heapLimit")(scrRegs[2], scrRegs[0]);

    // if (allocPtr + size > heapLimit) fallback
    as.cmp(scrRegs[1].opnd(64), scrRegs[2].opnd(64));
    as.jg(Label.FALLBACK);

    // Align the new incremented allocation pointer
    as.add(scrRegs[1].opnd(64), X86Opnd(7));
    as.and(scrRegs[1].opnd(64), X86Opnd(-8));

    // Store the incremented and aligned allocation pointer
    as.setMember!("VM.allocPtr")(scrRegs[0], scrRegs[1]);

    // Done allocating
    as.jmp(Label.DONE);

    // Allocation fallback
    as.label(Label.FALLBACK);

    as.saveJITRegs();

    //as.printStr("alloc bailout ***");

    // Call the fallback implementation
    as.ptr(cargRegs[0], instr);
    as.mov(cargRegs[1].opnd(32), szOpnd);
    as.ptr(scrRegs[0], &allocFallback);
    as.call(scrRegs[0]);

    //as.printStr("alloc bailout done ***");

    as.loadJITRegs();

    // Store the output value into the output operand
    as.mov(outOpnd, cretReg.opnd);

    // Allocation done
    as.label(Label.DONE);

    // Set the output type tag
    ctx.setOutTag(as, instr, tag);
}

alias gen_alloc_refptr = HeapAllocOp!(Tag.REFPTR);
alias gen_alloc_object = HeapAllocOp!(Tag.OBJECT);
alias gen_alloc_array = HeapAllocOp!(Tag.ARRAY);
alias gen_alloc_closure = HeapAllocOp!(Tag.CLOSURE);
alias gen_alloc_string = HeapAllocOp!(Tag.STRING);
alias gen_alloc_rope = HeapAllocOp!(Tag.ROPE);

void gen_gc_collect(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) void op_gc_collect(IRInstr curInstr, uint32_t heapSize)
    {
        vm.setCurInstr(curInstr);

        //writeln("triggering gc");

        gcCollect(vm, heapSize);

        vm.setCurInstr(null);
    }

    // Spill the values live before the instruction
    ctx.spillLiveBefore(as, instr);

    // Get the string pointer
    auto heapSizeOpnd = ctx.getWordOpnd(as, instr, 0, 32, X86Opnd.NONE, true, false);

    as.saveJITRegs();

    // Call the host function
    as.ptr(cargRegs[0], instr);
    as.mov(cargRegs[1].opnd(32), heapSizeOpnd);
    as.ptr(scrRegs[0], &op_gc_collect);
    as.call(scrRegs[0]);

    as.loadJITRegs();
}

void gen_get_str(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) refptr getStr(IRInstr curInstr, refptr strPtr)
    {
        vm.setCurInstr(curInstr);

        // Compute and set the hash code for the string
        auto hashCode = compStrHash(strPtr);
        str_set_hash(strPtr, hashCode);

        // Find the corresponding string in the string table
        auto str = getTableStr(vm, strPtr);

        vm.setCurInstr(null);

        return str;
    }

    // Spill the values live before this instruction
    ctx.spillLiveBefore(as, instr);

    // Get the string pointer
    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 64, X86Opnd.NONE, true, false);

    // Allocate the output operand
    auto outOpnd = ctx.getOutOpnd(as, instr, 64);

    as.saveJITRegs();

    // Call the fallback implementation
    as.ptr(cargRegs[0], instr);
    as.mov(cargRegs[1].opnd, opnd0);
    as.ptr(scrRegs[0], &getStr);
    as.call(scrRegs[0]);

    as.loadJITRegs();

    // Store the output value into the output operand
    as.mov(outOpnd, cretReg.opnd);

    // The output is a reference pointer
    ctx.setOutTag(as, instr, Tag.STRING);
}

void gen_break(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    assert (instr.getTarget(0) && instr.getTarget(1));
    assert (instr.getTarget(0).target is instr.getTarget(1).target);

    auto branch = getBranchEdge(instr.getTarget(0), ctx, false);

    // Generate the branch code
    ver.genBranch(
        as,
        branch,
        branch,
        delegate void(
            CodeBlock as,
            BlockVersion block,
            CodeFragment target0,
            CodeFragment target1,
            BranchShape shape
        )
        {
            final switch (shape)
            {
                case BranchShape.NEXT0:
                break;

                case BranchShape.NEXT1:
                break;

                case BranchShape.DEFAULT:
                jmp32Ref(as, vm, block, target0, 1);
            }
        }
    );
}

/// Inputs: any value x
/// Shifts us to version where the tag of the value is known
/// Implements a dynamic type tag dispatch/guard mechanism
void gen_capture_tag(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // If shape tag specialization is disabled, do nothing
    if (opts.shape_notagspec)
        return gen_jump_false(ver, ctx, instr, as);

    assert (instr.getTarget(0).args.length is 0);

    // Get the argument value
    auto argVal = instr.getArg(0);

    // Get type information about the argument
    ValType argType = ctx.getType(argVal);

    // If the type tag is marked as known
    if (argType.tagKnown)
    {
        // Jump directly to the false successor block
        return gen_jump_false(ver, ctx, instr, as);
    }

    auto argDst = cast(IRDstValue)argVal;
    assert (argDst !is null);

    // Get the current argument value type tag
    auto argTag = argDst? vm.getTag(argDst.outSlot):argType.tag;

    // Get the type operand
    auto tagOpnd = ctx.getTagOpnd(as, instr, 0);

    // Increment the capture_tag count
    as.incStatCnt(&stats.numTagTests, scrRegs[0]);

    // Increment the counter for this type tag test
    auto testName = "is_" ~ toLower(to!string(argTag));
    as.incStatCnt(stats.getTagTestCtr(testName), scrRegs[0]);

    // Compare this entry's type tag with the value's tag
    as.cmp(tagOpnd, X86Opnd(argTag));

    // On the recursive branch, no information is gained
    auto branchT = getBranchEdge(instr.getTarget(0), ctx, false);

    // Mark the value's type tag as known on the loop exit branch,
    // and queue this branch for immediate compilation (fall through)
    auto falseCtx = new CodeGenCtx(ctx);
    falseCtx.setTag(argDst, argTag);
    auto branchF = getBranchEdge(instr.getTarget(1), falseCtx, true);

    // Generate the branch code
    ver.genBranch(
        as,
        branchT,
        branchF,
        delegate void(
            CodeBlock as,
            BlockVersion block,
            CodeFragment target0,
            CodeFragment target1,
            BranchShape shape
        )
        {
            final switch (shape)
            {
                case BranchShape.NEXT0:
                je32Ref(as, vm, block, target1, 1);
                break;

                case BranchShape.NEXT1:
                jne32Ref(as, vm, block, target0, 0);
                break;

                case BranchShape.DEFAULT:
                jne32Ref(as, vm, block, target0, 0);
                jmp32Ref(as, vm, block, target1, 1);
            }
        }
    );
}

/// Inputs: obj, propName
/// Capture the shape of the object
/// This shifts us to a different version where the obj shape is known
/// Implements a dynamic shape dispatch/guard mechanism
void gen_capture_shape(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    assert (instr.getTarget(0).args.length is 0);

    // Get the object and shape argument values
    auto objVal = cast(IRDstValue)instr.getArg(0);
    auto shapeIdxVal = cast(IRDstValue)instr.getArg(1);
    assert (objVal !is null);
    assert (shapeIdxVal !is null);

    // If the object shape is already known
    if (ctx.shapeKnown(objVal))
    {
        // Increment the count of known shape instances
        as.incStatCnt(&stats.numShapeKnown, scrRegs[0]);

        // Exit the capture_chape chain early
        return gen_jump(ver, ctx, instr, as);
    }

    // If we hit the version limit, stop extending the capture_shape chain
    if (ctx.fun.versionMap.get(instr.block, []).length >= opts.maxvers)
    {
        return gen_jump(ver, ctx, instr, as);
    }

    // Increment the count of shape tests
    as.incStatCnt(&stats.numShapeTests, scrRegs[0]);

    // Observe the current shape index at compilation time
    assert (shapeIdxVal.block !is instr.block);
    auto curShapeIdx = vm.getWord(shapeIdxVal.outSlot).uint32Val;

    // Get the shape index operand
    auto shapeIdxOpnd = ctx.getWordOpnd(as, instr, 1, 32);

    // Compare the shape index operand with the observed shape index
    as.cmp(shapeIdxOpnd, X86Opnd(curShapeIdx));

    // On the exit (true) branch, mark the object shape as known
    // and queue this branch for immediate compilation (fall through)
    auto trueCtx = new CodeGenCtx(ctx);
    trueCtx.setShape(objVal, vm.objShapes[curShapeIdx]);
    auto branchT = getBranchEdge(instr.getTarget(0), trueCtx, true);

    // On the recursive (false) branch, no info about the object shape is
    // gained. We force the creation of a new version of the target block,
    // essentially unrolling/extending the capture_shape loop as needed.
    auto branchF = getBranchEdge(instr.getTarget(1), ctx, false, null, true);

    // Generate the branch code
    ver.genBranch(
        as,
        branchT,
        branchF,
        delegate void(
            CodeBlock as,
            BlockVersion block,
            CodeFragment target0,
            CodeFragment target1,
            BranchShape shape
        )
        {
            final switch (shape)
            {
                case BranchShape.NEXT0:
                jne32Ref(as, vm, block, target1, 1);
                break;

                case BranchShape.NEXT1:
                je32Ref(as, vm, block, target0, 0);
                break;

                case BranchShape.DEFAULT:
                je32Ref(as, vm, block, target0, 0);
                jmp32Ref(as, vm, block, target1, 1);
            }
        }
    );
}

void gen_clear_shape(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto objVal = cast(IRDstValue)instr.getArg(0);
    assert (objVal !is null);
    assert (objVal.block !is instr.block);

    ObjShape[ObjShape] shapes;

    // Gather all distinct shapes for the object value
    foreach (blockVer; ctx.fun.versionMap.get(instr.block, []))
    {
        auto blockCtx = blockVer.ctx;
        if (blockCtx.shapeKnown(objVal))
        {
            auto shape = blockCtx.getShape(objVal);
            shapes[shape] = shape;
        }
    }

    // If the number of shapes exceeds the maximum
    if (shapes.length > opts.maxshapes)
    {
        // Clear any known shape for this object
        ctx.shapeChg(as, objVal);
    }
}

/// Reads the shape index of an object, does nothing if the shape is known
/// Inputs: obj
void gen_read_shape_idx(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto objVal = cast(IRDstValue)instr.getArg(0);
    assert (objVal !is null);

    // Get the object operand
    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 64);
    assert (opnd0.isReg);

    // Get the output operand
    auto outOpnd = ctx.getOutOpnd(as, instr, 32);
    assert (outOpnd.isReg);

    // TODO: find way to have instr in valMap without allocating outOpnd?
    // want to avoid spilling reg if obj shape is known
    // ctx.noOutOpnd() ?

    // If the shape is known, do nothing
    if (ctx.shapeKnown(objVal))
    {
        ctx.setOutTag(as, instr, Tag.INT32);
        return;
    }

    // Read the object shape index
    as.getField(outOpnd.reg, opnd0.reg, obj_ofs_shape_idx(null));

    ctx.setOutTag(as, instr, Tag.INT32);
}

/// Initializes an object to the empty shape
/// Inputs: obj
void gen_obj_init_shape(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) void op_obj_init_shape(refptr objPtr, Tag protoTag)
    {
        // Get the initial object shape
        auto shape = vm.emptyShape.defProp(
            "__proto__",
            ValType(protoTag),
            ATTR_CONST_NOT_ENUM,
            null
        );

        obj_set_shape_idx(objPtr, shape.shapeIdx);

        assert (
            vm.wUpperLimit > vm.wStack,
            "invalid wStack after init shape"
        );
    }

    // Get the object operand
    auto objOpnd = ctx.getWordOpnd(as, instr, 0, 64);
    assert (objOpnd.isReg);

    // Get the type operand for the prototype argument
    auto tagOpnd = ctx.getTagOpnd(as, instr, 1);

    // If the prototype tag is a known constant or
    // property tag specialization is disabled
    if (tagOpnd.isImm || opts.shape_notagspec)
    {
        // Get the initial object shape
        auto shape = vm.emptyShape.defProp(
            "__proto__",
            tagOpnd.isImm? ValType(cast(Tag)tagOpnd.imm.imm):ValType(),
            ATTR_CONST_NOT_ENUM,
            null
        );

        // Set the object shape
        as.mov(X86Opnd(32, objOpnd.reg, obj_ofs_shape_idx(null)), X86Opnd(shape.shapeIdx));

        // Propagate the object shape
        ctx.setShape(cast(IRDstValue)instr.getArg(0), shape);

        return;
    }

    // Spill the values live before this instruction
    ctx.spillLiveBefore(as, instr);

    // Call the host function
    // Note: we move objOpnd first to avoid corruption
    as.mov(cargRegs[0].opnd(64), objOpnd);
    as.mov(cargRegs[1].opnd(8), tagOpnd);
    as.ptr(scrRegs[0], &op_obj_init_shape);
    as.call(scrRegs[0]);

    assert (!ctx.shapeKnown(cast(IRDstValue)instr.getArg(0)));
}

/// Initializes an array to the initial shape
/// Inputs: arr
void gen_arr_init_shape(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // Get the object operand
    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 64);
    assert (opnd0.isReg);

    // Set the array shape
    as.mov(
        X86Opnd(32, opnd0.reg, obj_ofs_shape_idx(null)),
        X86Opnd(vm.arrayShape.shapeIdx)
    );

    // Propagate the array shape
    ctx.setShape(cast(IRDstValue)instr.getArg(0), vm.arrayShape);
}

/// Sets the value of a property
/// Inputs: obj, propName, val
void gen_obj_set_prop(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static uint8_t op_shape_set_prop(IRInstr instr)
    {
        // Increment the host set prop stat
        ++stats.numSetPropHost;

        vm.setCurInstr(instr);

        auto objPair = vm.getArgVal(instr, 0);
        auto strPtr = vm.getArgStr(instr, 1);
        auto valPair = vm.getArgVal(instr, 2);

        auto propName = extractWStr(strPtr);
        //writeln("propName=", propName);

        // Get the shape of the object
        auto objShape = getShape(objPair.word.ptrVal);
        assert (objShape !is null);

        // Find the shape defining this property (if it exists)
        auto defShape = objShape.getDefShape(propName);

        // Set the property value
        setProp(
            objPair,
            propName,
            valPair
        );

        vm.setCurInstr(null);

        return (!defShape || defShape.isGetSet is false)? 1:0;
    }

    static void gen_slow_path(
        BlockVersion ver,
        CodeGenCtx ctx,
        IRInstr instr,
        CodeBlock as
    )
    {
        // Get the object value
        auto objVal = cast(IRDstValue)instr.getArg(0);

        // Spill the values live before this instruction
        ctx.spillLiveBefore(as, instr);

        as.saveJITRegs();

        // Call the host function
        as.ptr(cargRegs[0], instr);
        as.ptr(scrRegs[0], &op_shape_set_prop);
        as.call(scrRegs[0]);

        as.loadJITRegs();

        // Clear any known shape for this object
        ctx.shapeChg(as, objVal);

        // Check the success flag
        as.cmp(cretReg.opnd(8), X86Opnd(1));

        auto branchT = getBranchEdge(instr.getTarget(0), ctx, false);
        auto branchF = getBranchEdge(instr.getTarget(1), ctx, false);

        // Generate the branch code
        ver.genBranch(
            as,
            branchT,
            branchF,
            delegate void(
                CodeBlock as,
                BlockVersion block,
                CodeFragment target0,
                CodeFragment target1,
                BranchShape shape
            )
            {
                final switch (shape)
                {
                    case BranchShape.NEXT0:
                    jne32Ref(as, vm, block, target1, 1);
                    break;

                    case BranchShape.NEXT1:
                    je32Ref(as, vm, block, target0, 0);
                    break;

                    case BranchShape.DEFAULT:
                    je32Ref(as, vm, block, target0, 0);
                    jmp32Ref(as, vm, block, target1, 1);
                }
            }
        );
    }

    // Get the argument values
    auto objVal = cast(IRDstValue)instr.getArg(0);
    auto propVal = instr.getArg(2);

    // Increment the number of set prop operations
    as.incStatCnt(&stats.numSetProp, scrRegs[1]);
    if (objVal is ctx.fun.globalVal)
        as.incStatCnt(&stats.numSetGlobal, scrRegs[1]);

    // Extract the property name, if known
    auto propName = instr.getArgStrCst(1);

    // Get the type for the property value
    auto valType = ctx.getType(propVal).propType;

    // If the property name is unknown, use the slow path
    if (propName is null)
        return gen_slow_path(ver, ctx, instr, as);

    // If the object shape is unknown, use the slow path
    if (!ctx.shapeKnown(objVal))
        return gen_slow_path(ver, ctx, instr, as);

    // If we type of the property value is unknown and
    // shape tag specialization is enabled, use the slow path
    if (!valType.tagKnown && !opts.shape_notagspec)
        return gen_slow_path(ver, ctx, instr, as);

    // Get the object and defining shapes
    auto objShape = ctx.getShape(objVal);
    assert (objShape !is null);

    // Try a lookup for an existing property
    auto defShape = objShape.getDefShape(propName);

    // If the defining shape was not found
    if (defShape is null)
    {
        // If the object is not extensible, jump to the
        // true branch without adding the new property
        if (!objShape.extensible)
            return gen_jump(ver, ctx, instr, as);

        // Create a new shape for the property
        defShape = objShape.defProp(
            propName,
            valType,
            ATTR_DEFAULT,
            null
        );
    }

    // Get the property slot index
    auto slotIdx = defShape.slotIdx;
    assert (slotIdx !is PROTO_SLOT_IDX);

    // Compute the minimum object capacity we can guarantee
    auto minObjCap = (
        (objVal is ctx.fun.globalVal)?
        obj_get_cap(vm.globalObj.word.ptrVal):
        OBJ_MIN_CAP
    );

    // If the property has accessors, jump to the false branch
    if (defShape.isGetSet)
        return gen_jump_false(ver, ctx, instr, as);

    // If the shape is not writable, do nothing, jump to the true branch
    if (!defShape.writable)
        return gen_jump(ver, ctx, instr, as);

    // If the property already exists on the object
    if (slotIdx <= objShape.slotIdx)
    {
        auto objOpnd = ctx.getWordOpnd(as, instr, 0, 64);
        auto valOpnd = ctx.getWordOpnd(as, instr, 2, 64, scrRegs[2].opnd(64), true);
        auto tagOpnd = ctx.getTagOpnd(as, instr, 2, X86Opnd.NONE, true);
        assert (objOpnd.isReg);

        // Check if we need to write the type tag
        bool writeTag = (valType.tag != defShape.type.tag) || !defShape.type.tagKnown;

        // If we need to write the type tag or check the object capacity
        if (writeTag || slotIdx >= minObjCap)
        {
            // Get the object capacity into r1
            as.getField(scrRegs[1].reg(32), objOpnd.reg, obj_ofs_cap(null));
        }

        auto tblOpnd = objOpnd;

        // If we can't guarantee that the slot index is within capacity,
        // generate the extension table code
        if (slotIdx >= minObjCap)
        {
            tblOpnd = scrRegs[0].opnd;

            // Move the object operand into r0
            as.mov(tblOpnd, objOpnd);

            // If the slot index is below capacity, skip the ext table code
            as.cmp(scrRegs[1].opnd, X86Opnd(slotIdx));
            as.jg(Label.SKIP);

            // Get the ext table pointer into r0
            as.getField(tblOpnd.reg, tblOpnd.reg, obj_ofs_next(null));

            // If we need to write the type tag
            if (writeTag)
            {
                // Get the ext table capacity into r1
                as.getField(scrRegs[1].reg(32), tblOpnd.reg, obj_ofs_cap(null));
            }

            as.label(Label.SKIP);
        }

        // Store the word value
        auto wordMem = X86Opnd(64, tblOpnd.reg, OBJ_WORD_OFS + 8 * slotIdx);
        as.genMove(wordMem, valOpnd);

        // If we need to write the type tag
        if (writeTag)
        {
            // Store the type tag
            auto typeMem = X86Opnd(8 , tblOpnd.reg, OBJ_WORD_OFS + slotIdx, 8, scrRegs[1]);
            as.genMove(typeMem, tagOpnd, scrRegs[2].opnd);
        }

        // If the value type doesn't match the shape type
        if (!valType.isSubType(defShape.type))
        {
            // Create a new shape for the property
            objShape = objShape.defProp(
                propName,
                valType,
                ATTR_DEFAULT,
                defShape
            );

            // Write the object shape
            as.mov(
                X86Opnd(32, objOpnd.reg, obj_ofs_shape_idx(null)),
                X86Opnd(objShape.shapeIdx)
            );

            // Set the new object shape in the context
            ctx.shapeChg(as, objVal, objShape);

            // Increment the number of shape changes due to type
            as.incStatCnt(&stats.numShapeFlips, scrRegs[0]);
            if (objVal is ctx.fun.globalVal)
                as.incStatCnt(&stats.numShapeFlipsGlobal, scrRegs[0]);
        }

        // Property successfully set, jump to the true branch
        return gen_jump(ver, ctx, instr, as);
    }

    // This is a new property being added to the object
    // If the slot index is within the guaranteed object capacity
    if (slotIdx < minObjCap)
    {
        auto objOpnd = ctx.getWordOpnd(as, instr, 0, 64);
        auto valOpnd = ctx.getWordOpnd(as, instr, 2, 64, scrRegs[0].opnd(64), true);
        auto tagOpnd = ctx.getTagOpnd(as, instr, 2, scrRegs[1].opnd(8), true);
        assert (objOpnd.isReg);

        // Get the object capacity into r2
        as.getField(scrRegs[2].reg(32), objOpnd.reg, obj_ofs_cap(null));

        // Set the word and tag values
        auto wordMem = X86Opnd(64, objOpnd.reg, OBJ_WORD_OFS + 8 * slotIdx);
        auto typeMem = X86Opnd(8 , objOpnd.reg, OBJ_WORD_OFS + slotIdx, 8, scrRegs[2]);
        as.mov(wordMem, valOpnd);
        as.mov(typeMem, tagOpnd);

        // Update the object shape
        as.mov(
            X86Opnd(32, objOpnd.reg, obj_ofs_shape_idx(null)),
            X86Opnd(defShape.shapeIdx)
        );

        // Set the new object shape
        ctx.shapeChg(as, objVal, defShape);

        // Property successfully set, jump to the true branch
        return gen_jump(ver, ctx, instr, as);
    }

    // Use the slow path
    // Note: we don't check if the property goes in the extended
    // table because we cant guarantee the object size is sufficient
    // or that the extended table even exists
    return gen_slow_path(ver, ctx, instr, as);
}

/// Gets the value of a property
/// Inputs: obj, propName
void gen_obj_get_prop(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    struct OutVal
    {
        Word word;
        Tag tag;
        uint8_t success;
    }

    static assert (OutVal.sizeof == 2 * Word.sizeof);

    extern (C) static void op_obj_get_prop(
        OutVal* outVal,
        refptr objPtr,
        refptr strPtr
    )
    {
        // Increment the host get prop stat
        ++stats.numGetPropHost;

        // Get a temporary D string for the property name
        auto propStr = tempWStr(strPtr);

        // Get the shape of the object
        auto objShape = getShape(objPtr);
        assert (objShape !is null);

        // Find the shape defining this property (if it exists)
        auto defShape = objShape.getDefShape(propStr);

        // If the property doesn't exist
        if (defShape is null)
        {
            outVal.word = UNDEF.word;
            outVal.tag = UNDEF.tag;
            outVal.success = 0;
            return;
        }

        // Get the slot index and the object capacity
        uint32_t slotIdx = defShape.slotIdx;
        auto objCap = obj_get_cap(objPtr);

        if (slotIdx < objCap)
        {
            outVal.word = Word.int64v(obj_get_word(objPtr, slotIdx));
            outVal.tag = cast(Tag)obj_get_tag(objPtr, slotIdx);
        }
        else
        {
            auto extTbl = obj_get_next(objPtr);
            assert (slotIdx < obj_get_cap(extTbl));
            outVal.word = Word.int64v(obj_get_word(extTbl, slotIdx));
            outVal.tag = cast(Tag)obj_get_tag(extTbl, slotIdx);
        }

        outVal.success = (defShape.isGetSet is false)? 1:0;
    }

    static void gen_slow_path(
        BlockVersion ver,
        CodeGenCtx ctx,
        IRInstr instr,
        CodeBlock as
    )
    {
        // Spill the values live before this instruction
        ctx.spillLiveBefore(as, instr);

        // Get the object and string operands
        auto objOpnd = ctx.getWordOpnd(as, instr, 0, 64, X86Opnd.NONE, false, false);
        auto strOpnd = ctx.getWordOpnd(as, instr, 1, 64, scrRegs[0].opnd, false, false);

        auto outOpnd = ctx.getOutOpnd(as, instr, 64);

        as.saveJITRegs();

        // Stack allocate space for the value pair output
        as.sub(RSP, OutVal.sizeof);

        // Call the host function
        as.mov(cargRegs[0].opnd, RSP.opnd);
        as.mov(cargRegs[1].opnd, objOpnd);
        as.mov(cargRegs[2].opnd, strOpnd);
        as.ptr(scrRegs[0], &op_obj_get_prop);
        as.call(scrRegs[0]);

        // Free the extra stack space
        as.mov(scrRegs[0].opnd, RSP.opnd);
        as.add(RSP, OutVal.sizeof);

        as.loadJITRegs();

        auto wordMem = X86Opnd(64, scrRegs[0], OutVal.word.offsetof);
        auto tagMem = X86Opnd(8, scrRegs[0], OutVal.tag.offsetof);
        auto flagMem = X86Opnd(8, scrRegs[0], OutVal.success.offsetof);

        // Set the output word and tag
        as.mov(outOpnd, wordMem);
        as.mov(scrRegs[1].opnd(8), tagMem);
        ctx.setOutTag(as, instr, scrRegs[1].reg(8));

        // Check the success flag
        as.cmp(flagMem, X86Opnd(1));

        auto branchT = getBranchEdge(instr.getTarget(0), ctx, false);
        auto branchF = getBranchEdge(instr.getTarget(1), ctx, false);

        // Generate the branch code
        ver.genBranch(
            as,
            branchT,
            branchF,
            delegate void(
                CodeBlock as,
                BlockVersion block,
                CodeFragment target0,
                CodeFragment target1,
                BranchShape shape
            )
            {
                final switch (shape)
                {
                    case BranchShape.NEXT0:
                    jne32Ref(as, vm, block, target1, 1);
                    break;

                    case BranchShape.NEXT1:
                    je32Ref(as, vm, block, target0, 0);
                    break;

                    case BranchShape.DEFAULT:
                    je32Ref(as, vm, block, target0, 0);
                    jmp32Ref(as, vm, block, target1, 1);
                }
            }
        );
    }

    // Get the object argument
    auto objVal = cast(IRDstValue)instr.getArg(0);

    // Increment the number of get prop operations
    as.incStatCnt(&stats.numGetProp, scrRegs[1]);
    if (objVal is ctx.fun.globalVal)
        as.incStatCnt(&stats.numGetGlobal, scrRegs[1]);

    // Extract the property name, if known
    auto propName = instr.getArgStrCst(1);

    // If the property name is unknown, use the slow path
    if (propName is null)
        return gen_slow_path(ver, ctx, instr, as);

    // If the object shape is unknown, use the slow path
    if (!ctx.shapeKnown(objVal))
        return gen_slow_path(ver, ctx, instr, as);

    // Get the object and defining shapes
    auto objShape = ctx.getShape(objVal);
    assert (objShape !is null);

    // Try a lookup for an existing property
    auto defShape = objShape.getDefShape(propName);

    // If the property doesn't exist
    if (defShape is null)
    {
        auto outOpnd = ctx.getOutOpnd(as, instr, 64);

        // Set the output type tag
        ctx.setOutTag(as, instr, UNDEF.tag);

        // Jump to the false branch
        return gen_jump_false(ver, ctx, instr, as);
    }

    // Get the property slot index
    auto slotIdx = defShape.slotIdx;

    // Compute the minimum object capacity we can guarantee
    auto minObjCap = (
        (objVal is ctx.fun.globalVal)?
        obj_get_cap(vm.globalObj.word.ptrVal):
        OBJ_MIN_CAP
    );

    // No need to get the shape operand
    auto objOpnd = ctx.getWordOpnd(as, instr, 0, 64);
    assert (objOpnd.isReg);
    auto outOpnd = ctx.getOutOpnd(as, instr, 64);
    assert (outOpnd.isReg);

    // If we need to read the type tag or check the object capacity
    if (!defShape.type.tagKnown || slotIdx >= minObjCap)
    {
        // Get the object capacity into r1
        as.getField(scrRegs[1].reg(32), objOpnd.reg, obj_ofs_cap(null));
    }

    auto tblOpnd = objOpnd;

    // If we can't guarantee that the slot index is within capacity,
    // generate the extension table code
    if (slotIdx >= minObjCap)
    {
        tblOpnd = scrRegs[0].opnd;

        // Move the object operand into r0
        as.mov(tblOpnd, objOpnd);

        // If the slot index is below capacity, skip the ext table code
        as.cmp(scrRegs[1].opnd, X86Opnd(slotIdx));
        as.jg(Label.SKIP);

        // Get the ext table pointer into r0
        as.getField(tblOpnd.reg, tblOpnd.reg, obj_ofs_next(null));

        // If we need to read the type tag
        if (!defShape.type.tagKnown)
        {
            // Get the ext table capacity into r1
            as.getField(scrRegs[1].reg(32), tblOpnd.reg, obj_ofs_cap(null));
        }

        as.label(Label.SKIP);
    }

    // Load the word value
    auto wordMem = X86Opnd(64, tblOpnd.reg, OBJ_WORD_OFS + 8 * slotIdx);
    as.mov(outOpnd, wordMem);

    // If the property's type tag is known
    if (defShape.type.tagKnown)
    {
        // Propagate the shape type
        assert (!opts.shape_notagspec);
        ctx.setType(instr, defShape.type);
    }
    else
    {
        // Load the type value
        auto typeMem = X86Opnd(8, tblOpnd.reg, OBJ_WORD_OFS + slotIdx, 8, scrRegs[1]);
        as.mov(scrRegs[1].opnd(8), typeMem);
        ctx.setOutTag(as, instr, scrRegs[1].reg(8));
    }

    // If the property has accessors, jump to the false branch
    if (defShape.isGetSet)
        return gen_jump_false(ver, ctx, instr, as);

    // Normal property successfully read, jump to the true branch
    return gen_jump(ver, ctx, instr, as);
}

/// Get the prototype of an object
/// Inputs: obj
void gen_obj_get_proto(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // No need to get the shape operand
    auto objOpnd = ctx.getWordOpnd(as, instr, 0, 64);
    assert (objOpnd.isReg);
    auto outOpnd = ctx.getOutOpnd(as, instr, 64);
    assert (outOpnd.isReg);

    // Get the object type
    auto objType = ctx.getType(instr.getArg(0));

    auto slotIdx = PROTO_SLOT_IDX;

    // If the object shape is known
    if (objType.shapeKnown)
    {
        auto defShape = objType.shape.getDefShape("__proto__");
        assert (defShape !is null);
        assert (defShape.slotIdx is slotIdx);

        // If the shape's type tag is known
        if (defShape.type.tagKnown)
        {
            // Load the word value
            auto wordMem = X86Opnd(64, objOpnd.reg, OBJ_WORD_OFS + 8 * slotIdx);
            as.mov(outOpnd, wordMem);

            // Set the output type tag
            ctx.setOutTag(as, instr, defShape.type.tag);

            return;
        }
    }

    // Get the object capacity into r1
    as.getField(scrRegs[1].reg(32), objOpnd.reg, obj_ofs_cap(null));

    // Load the word and tag values
    auto wordMem = X86Opnd(64, objOpnd.reg, OBJ_WORD_OFS + 8 * slotIdx);
    auto typeMem = X86Opnd(8 , objOpnd.reg, OBJ_WORD_OFS + slotIdx, 8, scrRegs[1]);
    as.mov(outOpnd, wordMem);
    as.mov(scrRegs[2].opnd(8), typeMem);

    // Set the output type tag
    ctx.setOutTag(as, instr, scrRegs[2].reg(8));
}

/// Define a constant property
/// Inputs: obj, propName, val, enumerable
void gen_obj_def_const(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static void op_shape_def_const(IRInstr instr)
    {
        auto objPair = vm.getArgVal(instr, 0);
        auto strPtr = vm.getArgStr(instr, 1);
        auto valPair = vm.getArgVal(instr, 2);
        auto isEnum = vm.getArgBool(instr, 3);

        auto propStr = extractWStr(strPtr);

        // Attempt to define the constant
        defConst(
            objPair,
            propStr,
            valPair,
            isEnum
        );
    }

    // Get the object argument
    auto objDst = cast(IRDstValue)instr.getArg(0);
 
    // Spill the values live before this instruction
    ctx.spillLiveBefore(as, instr);

    as.saveJITRegs();

    // Call the host function
    as.ptr(cargRegs[0], instr);
    as.ptr(scrRegs[0], &op_shape_def_const);
    as.call(scrRegs[0]);

    as.loadJITRegs();

    // Clear any known shape for this object
    ctx.shapeChg(as, objDst);
}

/// Get the attributes associated with a given property
/// Note: null propName is used to get the attributes of the object shape
/// Note: the deleted attribute is produced if the property doesn't exist
/// Inputs: obj, propName
void gen_obj_get_attrs(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static uint32 op_obj_get_attrs(
        refptr objPtr, 
        refptr propName
    )
    {
        auto objShape = getShape(objPtr);

        // If no property name is specified
        if (propName is null)
            return objShape.attrs;

        auto defShape = objShape.getDefShape(extractWStr(propName));

        // If the property doesn't exist
        if (defShape is null)
            return ATTR_DELETED;

        return defShape.attrs;
    }

    // Spill the values live before this instruction
    ctx.spillLiveBefore(as, instr);

    auto objOpnd = ctx.getWordOpnd(as, instr, 0, 64, scrRegs[0].opnd, false, false);
    auto propOpnd = ctx.getWordOpnd(as, instr, 1, 64, scrRegs[1].opnd, false, false);
    auto outOpnd = ctx.getOutOpnd(as, instr, 32);

    //as.saveJITRegs();

    // Call the host function
    as.mov(cargRegs[0].opnd(64), objOpnd);
    as.mov(cargRegs[1].opnd(64), propOpnd);
    as.ptr(scrRegs[0], &op_obj_get_attrs);
    as.call(scrRegs[0]);

    // Set the output value
    as.mov(outOpnd, cretReg.opnd(32));
    ctx.setOutTag(as, instr, Tag.INT32);

    //as.loadJITRegs();
}

/// Sets the attributes for a given property
/// Note: null propName is used to set the attributes of the object shape
/// Inputs: obj, propName, attrBits
void gen_obj_set_attrs(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static void op_obj_set_attrs(IRInstr instr)
    {
        auto objPair = vm.getArgVal(instr, 0);
        auto propName = vm.getArgVal(instr, 1).word.ptrVal;
        auto newAttrs = vm.getArgUint32(instr, 2);

        auto objShape = getShape(objPair.word.ptrVal);

        // If no property name is specified
        if (propName is null)
        {
            // Attempt to set the property attributes
            setPropAttrs(
                objPair,
                objShape,
                cast(uint8_t)newAttrs
            );
        }
        else
        {
            auto defShape = objShape.getDefShape(extractWStr(propName));
            assert (defShape !is null);

            // Attempt to set the property attributes
            setPropAttrs(
                objPair,
                defShape,
                cast(uint8_t)newAttrs
            );
        }
    }

    // Spill the values live before this instruction
    ctx.spillLiveBefore(as, instr);

    as.saveJITRegs();

    // Call the host function
    as.ptr(cargRegs[0], instr);
    as.ptr(scrRegs[0], &op_obj_set_attrs);
    as.call(scrRegs[0]);

    as.loadJITRegs();

    // Clear any known shape for this object
    ctx.shapeChg(as, cast(IRDstValue)instr.getArg(0));
}

/// Get a table of enumerable property names for an object
/// Inputs: shape
void gen_obj_enum_tbl(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static refptr op_obj_enum_tbl(
        IRInstr curInstr,
        refptr objPtr
    )
    {
        vm.setCurInstr(curInstr);

        assert (objPtr !is null);

        auto objShape = getShape(objPtr);
        assert (objShape !is null);

        auto enumTbl = objShape.genEnumTbl();

        vm.setCurInstr(null);

        return enumTbl;
    }

    auto objVal = cast(IRDstValue)instr.getArg(0);
    assert (objVal !is null);

    // If the object shape is known
    if (ctx.shapeKnown(objVal))
    {
        auto objShape = ctx.getShape(objVal);
        objShape.genEnumTbl();

        auto outOpnd = ctx.getOutOpnd(as, instr, 64);
        assert (outOpnd.isReg);

        // Load the enum table pointer
        as.mov(RAX, &objShape.enumTbl.pair.word);
        as.mov(outOpnd, RAX.opnd);

        ctx.setOutTag(as, instr, Tag.REFPTR);

        return;
    }

    auto objOpnd = ctx.getWordOpnd(as, instr, 0, 64);
    assert (objOpnd.isReg);

    // Spill the values live after this instruction
    ctx.spillLiveAfter(as, instr);

    auto outOpnd = ctx.getOutOpnd(as, instr, 64);

    ctx.setOutTag(as, instr, Tag.REFPTR);

    as.saveJITRegs();

    // Call the host function
    as.mov(cargRegs[1].opnd(64), objOpnd);
    as.ptr(cargRegs[0], instr);
    as.ptr(scrRegs[0], &op_obj_enum_tbl);
    as.call(scrRegs[0]);

    // Set the output value
    as.mov(outOpnd, cretReg.opnd);

    as.loadJITRegs();

    as.label(Label.DONE);
}

void gen_set_global(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static void op_set_global(IRInstr instr)
    {
        // Property string (constant)
        auto strArg = cast(IRString)instr.getArg(0);
        assert (strArg !is null);
        auto propStr = strArg.str;

        auto valPair = vm.getArgVal(instr, 1);

        // Set the property value
        setProp(
            vm.globalObj,
            propStr,
            valPair
        );

        assert (obj_get_cap(vm.globalObj.word.ptrVal) > 0);
    }

    // Spill the values that are live before the call
    ctx.spillLiveBefore(as, instr);

    as.saveJITRegs();

    // Call the host function
    as.ptr(cargRegs[0], instr);
    as.ptr(scrRegs[0], &op_set_global);
    as.call(scrRegs[0]);

    as.loadJITRegs();
}

void gen_new_clos(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static refptr op_new_clos(
        IRInstr curInstr,
        IRFunction fun
    )
    {
        vm.setCurInstr(curInstr);

        // If the function has no entry point code
        if (fun.entryCode is null)
        {
            // Store the entry code pointer
            fun.entryCode = getEntryStub(fun);
        }

        // Allocate the closure object
        auto closPtr = GCRoot(
            newClos(
                vm.funProto,
                cast(uint32)fun.ast.captVars.length,
                fun
            )
        );

        // Allocate the prototype object
        auto objPtr = GCRoot(newObj(vm.objProto));

        // Set the "prototype" property on the closure object
        setProp(
            closPtr.pair,
            "prototype"w,
            objPtr.pair
        );

        assert (
            clos_get_next(closPtr.ptr) == null,
            "closure next pointer is not null"
        );

        //writeln("final clos ptr: ", closPtr.ptr);

        vm.setCurInstr(null);

        return closPtr.ptr;
    }

    // Spill all values live before this instruction
    ctx.spillValues(
        as,
        delegate bool(LiveInfo liveInfo, IRDstValue value)
        {
            return liveInfo.liveBefore(value, instr);
        }
    );

    auto funArg = cast(IRFunPtr)instr.getArg(0);
    assert (funArg !is null);
    assert (funArg.fun !is null);

    as.saveJITRegs();

    as.ptr(cargRegs[0], instr);
    as.ptr(cargRegs[1], funArg.fun);
    as.ptr(scrRegs[0], &op_new_clos);
    as.call(scrRegs[0]);

    as.loadJITRegs();

    auto outOpnd = ctx.getOutOpnd(as, instr, 64);
    as.mov(outOpnd, X86Opnd(cretReg));

    // Set the output type and mark the function pointer as known
    ValType outType = ValType(Tag.CLOSURE);
    outType.fptrKnown = true;
    outType.fptr = funArg.fun;
    ctx.setType(instr, outType);
}

void gen_print_str(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static void printStr(refptr strPtr)
    {
        // Extract a D string
        auto str = extractStr(strPtr);

        // Print the string to standard output
        write(str);
    }

    auto strOpnd = ctx.getWordOpnd(as, instr, 0, 64, X86Opnd.NONE, false, false);

    as.pushRegs();

    as.mov(cargRegs[0].opnd(64), strOpnd);
    as.ptr(scrRegs[0], &printStr);
    as.call(scrRegs[0].opnd(64));

    as.popRegs();
}

void gen_print_ptr(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    auto opnd = ctx.getWordOpnd(as, instr, 0, 64, scrRegs[0].opnd, false, false);

    as.printPtr(opnd);
}

void gen_get_time_ms(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static double op_get_time_ms()
    {
        long currTime = Clock.currStdTime();
        long epochTime = 621355968000000000; // unixTimeToStdTime(0);
        double retVal = cast(double)((currTime - epochTime)/10000);
        return retVal;
    }

    // Spill the values live after this instruction
    ctx.spillValues(
        as,
        delegate bool(LiveInfo liveInfo, IRDstValue value)
        {
            return liveInfo.liveAfter(value, instr);
        }
    );

    as.saveJITRegs();

    as.ptr(scrRegs[0], &op_get_time_ms);
    as.call(scrRegs[0].opnd(64));

    as.loadJITRegs();

    auto outOpnd = ctx.getOutOpnd(as, instr, 64);
    as.movq(outOpnd, X86Opnd(XMM0));
    ctx.setOutTag(as, instr, Tag.FLOAT64);
}

void gen_get_ast_str(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static refptr op_get_ast_str(
        IRInstr curInstr,
        refptr closPtr
    )
    {
        vm.setCurInstr(curInstr);

        assert (
            refIsLayout(closPtr, LAYOUT_CLOS),
            "invalid closure object"
        );

        auto fun = getFunPtr(closPtr);

        auto str = fun.ast.toString();
        auto strObj = getString(vm, to!wstring(str));

        vm.setCurInstr(null);

        return strObj;
    }

    // Spill the values live before this instruction
    ctx.spillValues(
        as,
        delegate bool(LiveInfo liveInfo, IRDstValue value)
        {
            return liveInfo.liveBefore(value, instr);
        }
    );

    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 64, X86Opnd.NONE, false, false);

    as.saveJITRegs();

    as.ptr(cargRegs[0], instr);
    as.mov(cargRegs[1].opnd, opnd0);
    as.ptr(scrRegs[0], &op_get_ast_str);
    as.call(scrRegs[0].opnd);

    as.loadJITRegs();

    auto outOpnd = ctx.getOutOpnd(as, instr, 64);
    as.mov(outOpnd, X86Opnd(RAX));
    ctx.setOutTag(as, instr, Tag.STRING);
}

void gen_get_ir_str(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static refptr op_get_ir_str(
        IRInstr curInstr,
        refptr closPtr
    )
    {
        vm.setCurInstr(curInstr);

        assert (
            refIsLayout(closPtr, LAYOUT_CLOS),
            "invalid closure object"
        );

        auto fun = getFunPtr(closPtr);

        // If the function is not yet compiled, compile it now
        if (fun.entryBlock is null)
        {
            astToIR(fun.ast, fun);
        }

        auto str = fun.toString();
        auto strObj = getString(vm, to!wstring(str));

        vm.setCurInstr(null);

        return strObj;
    }

    // Spill the values live before this instruction
    ctx.spillValues(
        as,
        delegate bool(LiveInfo liveInfo, IRDstValue value)
        {
            return liveInfo.liveBefore(value, instr);
        }
    );

    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 64, X86Opnd.NONE, false, false);

    as.saveJITRegs();

    as.ptr(cargRegs[0], instr);
    as.mov(cargRegs[1].opnd, opnd0);
    as.ptr(scrRegs[0], &op_get_ir_str);
    as.call(scrRegs[0].opnd);

    as.loadJITRegs();

    auto outOpnd = ctx.getOutOpnd(as, instr, 64);
    as.mov(outOpnd, X86Opnd(RAX));
    ctx.setOutTag(as, instr, Tag.STRING);
}

void gen_get_asm_str(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static refptr op_get_asm_str(
        IRInstr curInstr,
        refptr closPtr
    )
    {
        vm.setCurInstr(curInstr);

        assert (
            refIsLayout(closPtr, LAYOUT_CLOS),
            "invalid closure object"
        );

        auto fun = getFunPtr(closPtr);

        // Generate a string representation of the code
        string str = asmString(fun);

        // Get a string object for the output
        auto strObj = getString(vm, to!wstring(str));

        vm.setCurInstr(null);

        return strObj;
    }

    // Spill the values live before this instruction
    ctx.spillValues(
        as,
        delegate bool(LiveInfo liveInfo, IRDstValue value)
        {
            return liveInfo.liveBefore(value, instr);
        }
    );

    auto opnd0 = ctx.getWordOpnd(as, instr, 0, 64, X86Opnd.NONE, false, false);

    as.saveJITRegs();

    as.ptr(cargRegs[0], instr);
    as.mov(cargRegs[1].opnd, opnd0);
    as.ptr(scrRegs[0], &op_get_asm_str);
    as.call(scrRegs[0].opnd);

    as.loadJITRegs();

    auto outOpnd = ctx.getOutOpnd(as, instr, 64);
    as.mov(outOpnd, X86Opnd(RAX));
    ctx.setOutTag(as, instr, Tag.STRING);
}

void gen_load_lib(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static CodePtr op_load_lib(IRInstr instr)
    {
        // Library to load (JS string)
        auto strPtr = vm.getArgStr(instr, 0);

        // Library to load (D string)
        auto libname = extractStr(strPtr);

        // Let the user specify just the lib name without the extension
        if (libname.length > 0 && libname.countUntil('/') == -1)
        {
            if (libname.countUntil('.') == -1)
            {
                version (linux) libname ~= ".so";
                version (OSX) libname ~= ".dylib";
            }

            if (libname[0] != 'l' && libname[1] != 'i' && libname[2] != 'b')
            {
                libname = "lib" ~ libname;
            }
        }

        // Filename must be either a zero-terminated string or null
        auto filename = libname ? toStringz(libname) : null;

        // If filename is null the returned handle will be the main program
        auto lib = dlopen(filename, RTLD_LAZY | RTLD_LOCAL);

        if (lib is null)
        {
            return throwError(
                instr,
                null,
                "ReferenceError",
                to!string(dlerror())
            );
        }

        vm.push(Word.ptrv(cast(rawptr)lib), Tag.RAWPTR);

        return null;

    }

    // Spill the values live before this instruction
    ctx.spillValues(
        as,
        delegate bool(LiveInfo liveInfo, IRDstValue value)
        {
            return liveInfo.liveBefore(value, instr);
        }
    );

    auto outOpnd = ctx.getOutOpnd(as, instr, 64);

    as.saveJITRegs();
    as.ptr(cargRegs[0], instr);
    as.ptr(scrRegs[0], &op_load_lib);
    as.call(scrRegs[0].opnd);
    as.loadJITRegs();

    // If an exception was thrown, jump to the exception handler
    as.cmp(cretReg.opnd, X86Opnd(0));
    as.je(Label.FALSE);
    as.jmp(cretReg.opnd);
    as.label(Label.FALSE);

    // Get the lib handle from the stack
    as.getWord(scrRegs[0], 0);
    as.add(wspReg, Word.sizeof);
    as.add(tspReg, Tag.sizeof);
    as.mov(outOpnd, scrRegs[0].opnd);
    ctx.setOutTag(as, instr, Tag.RAWPTR);
}

void gen_close_lib(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static CodePtr op_close_lib(IRInstr instr)
    {
        auto libArg = vm.getArgVal(instr, 0);

        assert (
            libArg.tag == Tag.RAWPTR,
            "invalid rawptr value"
        );

        if (dlclose(libArg.word.ptrVal) != 0)
        {
            return throwError(
                instr,
                null,
                "RuntimeError",
                "Could not close lib."
            );
        }

        return null;
    }

    // Spill the values live before this instruction
    ctx.spillValues(
        as,
        delegate bool(LiveInfo liveInfo, IRDstValue value)
        {
            return liveInfo.liveBefore(value, instr);
        }
    );

    as.saveJITRegs();
    as.ptr(cargRegs[0], instr);
    as.ptr(scrRegs[0], &op_close_lib);
    as.call(scrRegs[0].opnd);
    as.loadJITRegs();

    // If an exception was thrown, jump to the exception handler
    as.cmp(cretReg.opnd, X86Opnd(0));
    as.je(Label.FALSE);
    as.jmp(cretReg.opnd);
    as.label(Label.FALSE);
}

void gen_get_sym(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) static CodePtr op_get_sym(IRInstr instr)
    {
        auto libArg = vm.getArgVal(instr, 0);

        assert (
            libArg.tag == Tag.RAWPTR,
            "get_sym: invalid lib rawptr value"
        );

        // Symbol name string
        auto strArg = cast(IRString)instr.getArg(1);
        assert (strArg !is null);
        auto symname = to!string(strArg.str);

        // String must be null terminated
        auto sym = dlsym(libArg.word.ptrVal, toStringz(symname));

        if (sym is null)
        {
            return throwError(
                instr,
                null,
                "RuntimeError",
                to!string(dlerror())
            );
        }

        vm.push(Word.ptrv(cast(rawptr)sym), Tag.RAWPTR);

        return null;
    }

    // Spill the values live before this instruction
    ctx.spillLiveBefore(as, instr);

    auto outOpnd = ctx.getOutOpnd(as, instr, 64);

    as.saveJITRegs();
    as.ptr(cargRegs[0], instr);
    as.ptr(scrRegs[0], &op_get_sym);
    as.call(scrRegs[0].opnd);
    as.loadJITRegs();

    // If an exception was thrown, jump to the exception handler
    as.cmp(cretReg.opnd, X86Opnd(0));
    as.je(Label.FALSE);
    as.jmp(cretReg.opnd);
    as.label(Label.FALSE);

    // Get the sym handle from the stack
    as.getWord(scrRegs[0], 0);
    as.add(wspReg, Word.sizeof);
    as.add(tspReg, Tag.sizeof);
    as.mov(outOpnd, scrRegs[0].opnd);
    ctx.setOutTag(as, instr, Tag.RAWPTR);

}

// Mappings for arguments/return values
Tag[string] typeMap;
size_t[string] sizeMap;
static this()
{
    typeMap = [
        "i8"  : Tag.INT32,
        "i16" : Tag.INT32,
        "i32" : Tag.INT32,
        "i64" : Tag.INT64,
        "u8"  : Tag.INT32,
        "u16" : Tag.INT32,
        "u32" : Tag.INT32,
        "u64" : Tag.INT64,
        "f64" : Tag.FLOAT64,
        "*"   : Tag.RAWPTR
    ];

    sizeMap = [
        "i8" : 8,
        "i16" : 16,
        "i32" : 32,
        "i64" : 64,
        "u8" : 8,
        "u16" : 16,
        "u32" : 32,
        "u64" : 64,
        "f64" : 64,
        "*" : 64
    ];
}

void gen_call_ffi(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    // Get the function signature
    auto sigStr = cast(IRString)instr.getArg(1);
    assert (sigStr !is null, "null sigStr in call_ffi.");
    auto typeinfo = to!string(sigStr.str);
    auto types = split(typeinfo, ",");

    // Track register usage for args
    auto iArgIdx = 0;
    auto fArgIdx = 0;

    // Return type of the FFI call
    auto retType = types[0];

    // Argument types the call expects
    auto argTypes = types[1..$];

    // The number of args actually passed
    auto argCount = cast(uint32_t)instr.numArgs - 2;
    assert(
        argTypes.length == argCount,
        "incorrect arg count in call_ffi"
    );

    // Spill the values live before this instruction
    ctx.spillLiveBefore(as, instr);

    // outOpnd
    auto outOpnd = ctx.getOutOpnd(as, instr, 64);

    // Indices of arguments to be pushed on the stack
    size_t[] stackArgs;

    // Set up arguments
    for (size_t idx = 0; idx < argCount; ++idx)
    {
        // Either put the arg in the appropriate register
        // or set it to be pushed to the stack later
        if (argTypes[idx] == "f64" && fArgIdx < cfpArgRegs.length)
        {
            auto argOpnd = ctx.getWordOpnd(
                as,
                instr,
                idx + 2,
                64,
                scrRegs[0].opnd(64),
                true,
                false
            );
            as.movq(cfpArgRegs[fArgIdx++].opnd, argOpnd);
        }
        else if (iArgIdx < cargRegs.length)
        {
            auto argSize = sizeMap[argTypes[idx]];
            auto argOpnd = ctx.getWordOpnd(
                as,
                instr,
                idx + 2,
                argSize,
                scrRegs[0].opnd(argSize),
                true,
                false
            );
            auto cargOpnd = cargRegs[iArgIdx++].opnd(argSize);
            as.mov(cargOpnd, argOpnd);
        }
        else
        {
            stackArgs ~= idx;
        }
    }

    // Save the JIT registers
    as.saveJITRegs();

    // Make sure there is an even number of pushes
    if (stackArgs.length % 2 != 0)
        as.push(scrRegs[0]);

    // Push the stack arguments, in reverse order
    foreach_reverse (idx; stackArgs)
    {
        auto argSize = sizeMap[argTypes[idx]];
        auto argOpnd = ctx.getWordOpnd(
            as,
            instr,
            idx + 2,
            argSize,
            scrRegs[0].opnd(argSize),
            true,
            false
        );
        as.mov(scrRegs[0].opnd(argSize), argOpnd);
        as.push(scrRegs[0]);
    }

    // Pointer to function to call
    auto funArg = ctx.getWordOpnd(
        as,
        instr,
        0,
        64,
        scrRegs[0].opnd(64),
        false,
        false
    );

    debug
    {
        as.checkStackAlign("stack unaligned before FFI call");
    }

    // call the function
    as.call(scrRegs[0].opnd);

    // Pop the stack arguments
    foreach (idx; stackArgs)
        as.pop(scrRegs[1]);

    // Make sure there is an even number of pops
    if (stackArgs.length % 2 != 0)
        as.pop(scrRegs[1]);

    // Restore the JIT registers
    as.loadJITRegs();

    // Send return value/type
    if (retType == "f64")
    {
        as.movq(outOpnd, X86Opnd(XMM0));
        ctx.setOutTag(as, instr, typeMap[retType]);
    }
    else if (retType == "void")
    {
        as.mov(outOpnd, X86Opnd(UNDEF.word.int8Val));
        ctx.setOutTag(as, instr, UNDEF.tag);
    }
    else
    {
        as.mov(outOpnd, X86Opnd(RAX));
        ctx.setOutTag(as, instr, typeMap[retType]);
    }

    // Jump directly to the successor block
    return gen_jump(ver, ctx, instr, as);
}

void gen_get_c_fptr(
    BlockVersion ver,
    CodeGenCtx ctx,
    IRInstr instr,
    CodeBlock as
)
{
    extern (C) CodePtr genCEntry(IRInstr instr)
    {
        // Get the function signature
        auto sigStr = cast(IRString)instr.getArg(1);
        assert (sigStr !is null, "null sigStr in call_ffi.");
        auto types = to!string(sigStr.str).split();
        auto argTypes = types[1..$];
        auto numArgs = argTypes.length;

        // Get the IRFunction
        auto closPtr = vm.getArgVal(instr, 0).word.ptrVal;
        assert (closPtr !is null);
        auto fun = getFunPtr(closPtr);

        // If a C entry point was already generated
        if (fun.cEntryCode !is null)
        {
            return throwError(
                instr,
                null,
                "RuntimeError",
                "get_c_fptr: entry point already generated"
            );
        }

        // Allocate a block of executable memory
        fun.cEntryCode = new CodeBlock(1000, false);





        /*
        FIXME: issue.... wsp and tsp
        can get those from the VM object


        FIXME: still an issue of stack traversal
        GC traverses chain of ret addrs

        Can't unwind through C calls... Which is OK.
        - Can have the user take special provisions

        But what about the GC?
        Would need an RA to tell us who the next function is


        */




        // TODO: get a basic call with no args working first
        // Look at optimized call code





        /*
        // Compute the number of locals in this frame
        auto frameSize = fun.numLocals + numExtra;

        // Copy the function arguments supplied
        for (int32_t i = 0; i < numArgs; ++i)
        {
            auto instrArgIdx = 2 + i;
            auto dstIdx = -(numArgs - i);

            // Copy the argument word
            auto argOpnd = ctx.getWordOpnd(
                as,
                instr,
                instrArgIdx,
                64,
                scrRegs[1].opnd(64),
                true,
                false
            );
            as.setWord(dstIdx, argOpnd);

            // Copy the argument type
            auto tagOpnd = ctx.getTagOpnd(
                as,
                instr,
                instrArgIdx,
                scrRegs[1].opnd(8),
                true
            );
            as.setTag(dstIdx, tagOpnd);
        }

        // Write undefined values for the missing arguments
        for (int32_t i = 0; i < numMissing; ++i)
        {
            auto dstIdx = -(i + 1);

            as.setWord(dstIdx, UNDEF.word.int8Val);
            as.setTag(dstIdx, UNDEF.tag);
        }

        // Write the argument count
        as.setWord(-numArgs - 1, numArgs);

        // Write the "this" argument
        if (fun.thisVal.hasUses)
        {
            auto thisReg = ctx.getWordOpnd(
                as,
                instr,
                1,
                64,
                scrRegs[1].opnd(64),
                true,
                false
            );
            as.setWord(-numArgs - 2, thisReg);
            auto tagOpnd = ctx.getTagOpnd(
                as,
                instr,
                1,
                scrRegs[1].opnd(8),
                true
            );
            as.setTag(-numArgs - 2, tagOpnd);
        }

        // Write the closure argument
        if (fun.closVal.hasUses)
        {
            auto closReg = ctx.getWordOpnd(
                as,
                instr,
                0,
                64,
                scrRegs[0].opnd(64),
                false,
                false
            );
            as.setWord(-numArgs - 3, closReg);
        }

        // Spill the values that are live after the call
        ctx.spillLiveBefore(as, instr);

        // Clear the known shape information
        ctx.clearShapes();

        // Push space for the callee arguments and locals
        as.sub(X86Opnd(tspReg), X86Opnd(frameSize));
        as.sub(X86Opnd(wspReg), X86Opnd(8 * frameSize));

        // Request an instance for the function entry block
        auto entryVer = getBlockVersion(
            fun.entryBlock,
            new CodeGenCtx(fun)
        );
        */



        // TODO: create RA entry for this?


        /*
        // Get the return address slot of the callee
        auto raSlot = entryVer.block.fun.raVal.outSlot;
        assert (raSlot !is NULL_STACK);

        // Write the return address on the stack
        as.movAbsRef(vm, scrRegs[0], block, target0, 0);
        as.setWord(raSlot, scrRegs[0].opnd(64));

        // Jump to the function entry block
        jmp32Ref(as, vm, block, entryVer, 0);
        */











        // TODO: compile the entry point

        vm.setCurInstr(instr);


        vm.setCurInstr(null);



        // TODO: Return to the calling code
        //as.ret();










        // Push the entry point address on the stack
        auto codePtr = fun.cEntryCode.getAddress;
        vm.push(Word.ptrv(cast(rawptr)codePtr), Tag.RAWPTR);

        // Return null, meaning no exception thrown
        return null;
    }

    // Spill the values live before this instruction
    ctx.spillLiveBefore(as, instr);

    // Allocate the output operand
    auto outOpnd = ctx.getOutOpnd(as, instr, 64);

    as.saveJITRegs();
    as.ptr(cargRegs[0], instr);
    as.ptr(scrRegs[0], &genCEntry);
    as.call(scrRegs[0].opnd);
    as.loadJITRegs();

    // If an exception was thrown, jump to the exception handler
    as.cmp(cretReg.opnd, X86Opnd(0));
    as.je(Label.FALSE);
    as.jmp(cretReg.opnd);
    as.label(Label.FALSE);

    // Get the sym handle from the stack
    as.getWord(scrRegs[0], 0);
    as.add(wspReg, Word.sizeof);
    as.add(tspReg, Tag.sizeof);
    as.mov(outOpnd, scrRegs[0].opnd);
    ctx.setOutTag(as, instr, Tag.RAWPTR);
}

