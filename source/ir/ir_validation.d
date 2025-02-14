///Copyright: Copyright (c) 2017-2019 Andrey Penechko.
///License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
///Authors: Andrey Penechko.

/// IR Validation routines
module ir.ir_validation;

import all;
import ir.ir_index;

///
void validateIrFunction(CompilationContext* context, IrFunction* ir)
{
	scope(failure) dumpFunction(context, ir);

	auto funcInstrInfos = allInstrInfos[ir.instructionSet];
	auto instrValidator = instrValidators[ir.instructionSet];

	foreach (IrIndex blockIndex, ref IrBasicBlock block; ir.blocks)
	{
		context.assertf(blockIndex.storageUintIndex < ir.numBasicBlocks, "basic block out of bounds %s", blockIndex);

		if (!block.isSealed)
		{
			context.internal_error("Unsealed basic block %s", blockIndex);
		}

		if (!block.isFinished)
		{
			context.internal_error("Unfinished basic block %s", blockIndex);
		}

		IrInstrHeader* firstInstr = ir.getInstr(block.firstInstr);
		IrInstrHeader* lastInstr = ir.getInstr(block.lastInstr);
		context.assertf(funcInstrInfos[lastInstr.op].isBlockExit,
			"Basic block %s does not end with jump, branch or return instruction",
			blockIndex);

		// Check that all users of virtual reg point to definition
		void checkArg(IrIndex argUser, IrIndex arg)
		{
			if (!arg.isVirtReg) return;

			IrVirtualRegister* vreg = ir.getVirtReg(arg);

			// Check case when virtual register is in use,
			// but it's definition point is not set
			context.assertf(vreg.definition.isDefined,
				"Virtual register %s, invalid definition (%s)",
				arg, vreg.definition);

			// How many times 'argUser' is found in vreg.users
			uint numVregUses = vreg.users.contains(ir, argUser);

			// How many times 'args' is found in instr.args
			uint timesUsed = 0;

			if (argUser.isInstruction)
			{
				foreach (i, IrIndex instrArg; ir.getInstr(argUser).args(ir))
					if (instrArg == arg)
						++timesUsed;
			}
			else if (argUser.isPhi)
			{
				foreach(size_t arg_i, ref IrIndex phiArg; ir.getPhi(argUser).args(ir))
					if (phiArg == arg)
						++timesUsed;
			}
			else
			{
				context.internal_error("Virtual register cannot be used by %s", argUser.kind);
			}

			// For each use of arg by argUser there must one item in users list of vreg and in args list of user
			context.assertf(numVregUses == timesUsed,
				"Virtual register %s appears %s times as argument of %s, but instruction appears as user %s times",
					arg, timesUsed, argUser, numVregUses);
		}

		void checkResult(IrIndex definition, IrIndex result)
		{
			if (!result.isVirtReg) return;

			IrVirtualRegister* vreg = ir.getVirtReg(result);

			// Type must be set for every virtual register
			context.assertf(vreg.type.isType,
				"Virtual register %s, invalid type (%s)",
				result, vreg.type);

			// Check that all users of virtual reg point to definition
			context.assertf(vreg.definition == definition,
				"Virtual register %s definition %s doesn't match instruction %s",
				result, vreg.definition, definition);

			foreach (IrIndex user, uint numUses; vreg.users.range(ir))
				checkArg(user, result);
		}

		foreach(IrIndex phiIndex, ref IrPhi phi; block.phis(ir))
		{
			size_t numPhiArgs = 0;
			size_t numUniqueArgs = 0; // not an exact count, but precise in [0..2] range
			IrIndex uniqueValue;
			foreach(size_t arg_i, ref IrIndex phiArg; phi.args(ir))
			{
				++numPhiArgs;
				checkArg(phiIndex, phiArg);

				if (phiArg == uniqueValue || phiArg == phi.result) {
					continue;
				}
				// assignment will be done first time when uniqueValue is undefined and phiArg != phi.result
				// second time when phiArg != uniqueValue and phiArg != phi.result,
				// so, we are looking for numUniqueArgs > 1
				uniqueValue = phiArg;
				++numUniqueArgs;
			}

			// check that phi function is not redundant
			context.assertf(numUniqueArgs > 1, "%s is redundant", phiIndex);

			// TODO: check that all types of args match type of result

			// TODO: check correspondense of basic block indicies with phi arg indicies

			// check that phi-function receives values from all predecessors
			size_t numPredecessors = 0;
			foreach(IrIndex predIndex; block.predecessors.range(ir))
			{
				context.assertf(predIndex.storageUintIndex < ir.numBasicBlocks, "basic block out of bounds %s", predIndex);
				++numPredecessors;
			}
			context.assertf(numPredecessors == block.predecessors.length,
				"Corrupted list of predecessors %s != %s",
				numPredecessors, block.predecessors.length);

			context.assertf(numPhiArgs == numPredecessors,
				"Number of predecessors: %s doesn't match number of phi arguments: %s",
				numPredecessors, numPhiArgs);

			checkResult(phiIndex, phi.result);
			//writefln("phi %s args %s preds %s", phiIndex, numPhiArgs, numPredecessors);
		}

		foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; block.instructions(ir))
		{
			foreach (i, IrIndex arg; instrHeader.args(ir))
			{
				checkArg(instrIndex, arg);
			}

			if (instrHeader.hasResult)
			{
				checkResult(instrIndex, instrHeader.result(ir));
			}

			if (funcInstrInfos[instrHeader.op].isBlockExit)
			{
				context.assertf(block.lastInstr == instrIndex,
					"Basic block %s has %s as last instruction, not branch %s",
					blockIndex, block.lastInstr, instrIndex);

				context.assertf(ir.nextInstr(instrIndex) == blockIndex,
					"Branch %s has %s as next instruction, not basic block %s",
					instrIndex, ir.nextInstr(instrIndex), blockIndex);
			}

			instrValidator(context, ir, instrIndex, instrHeader);
		}
	}
}

immutable void function(CompilationContext*, IrFunction*, IrIndex, ref IrInstrHeader)[] instrValidators = [
	&validateIrInstruction, // ir
	&validateIrInstruction_dummy, // lir_amd64
];

// TODO: check all instructions
void validateIrInstruction(CompilationContext* c, IrFunction* ir, IrIndex instrIndex, ref IrInstrHeader instrHeader)
{
	switch(instrHeader.op)
	{
		case IrOpcode.load:
			IrIndex ptr = instrHeader.arg(ir, 0);
			IrIndex value = instrHeader.result(ir);
			if (ptr.isPhysReg || value.isPhysReg) break;

			IrIndex ptrType = getValueType(ptr, ir, c);
			c.assertf(ptrType.isTypePointer, "%s: first argument must be pointer, not: %s", instrIndex, ptrType.kind);
			IrIndex valueType = getValueType(value, ir, c);
			IrIndex baseType = c.types.getPointerBaseType(ptrType);
			c.assertf(c.types.isSameType(baseType, valueType), "%s: cannot load %s from %s",
				instrIndex, IrIndexDump(valueType, c, ir), IrIndexDump(ptrType, c, ir));
			break;

		case IrOpcode.store:
			IrIndex ptr = instrHeader.arg(ir, 0);
			IrIndex value = instrHeader.arg(ir, 1);
			if (ptr.isPhysReg || value.isPhysReg) break;

			IrIndex ptrType = getValueType(ptr, ir, c);
			c.assertf(ptrType.isTypePointer, "%s: first argument must be pointer, not: %s", instrIndex, ptrType.kind);
			IrIndex valueType = getValueType(value, ir, c);
			IrIndex baseType = c.types.getPointerBaseType(ptrType);
			if (c.types.isSameType(baseType, valueType)) {
				break; // ok
			} else if (value.isSimpleConstant) {
				// constant is stored into memory
				if (baseType.isTypeBasic && valueType.typeIndex <= baseType.typeIndex) {
					break; // ok. Constant is stored into big enough memory slot
				} else if (baseType.isTypePointer) {
					break; // ok. Constant is stored into ptr sized slot
				}
			}
			c.internal_error("%s: cannot store %s %s into %s",
				instrIndex, IrIndexDump(value, c, ir), IrIndexDump(valueType, c, ir), IrIndexDump(ptrType, c, ir));
			break;

		case IrOpcode.create_aggregate:
			c.assertf(instrHeader.hasResult, "%s: create_aggregate has no result", instrIndex);

			IrIndex result = instrHeader.result(ir);
			c.assertf(result.isVirtReg, "%s: create_aggregate result is %s. virtualRegister expected", instrIndex, result.kind);

			IrVirtualRegister* vreg = ir.getVirtReg(result);
			c.assertf(vreg.type.isType, "%s: result type is not a type: %s", instrIndex, vreg.type.kind);

			if (vreg.type.isTypeStruct)
			{
				IrTypeStruct* structType = &c.types.get!IrTypeStruct(vreg.type);
				IrTypeStructMember[] structMembers = structType.members;
				if (structType.isUnion)
				{
					c.assertf(instrHeader.numArgs == 2,
						"%s: create_aggregate invalid number of arguments for union type, got %s, expected 2",
						instrIndex, instrHeader.numArgs);
					IrIndex index = instrHeader.arg(ir, 0);
					c.assertf(index.isSimpleConstant,
						"%s: create_aggregate agr 0 must contain constant index, got %s",
						instrIndex, IrIndexDump(index, c, ir));
					ulong indexVal = c.constants.get(index).i64;
					c.assertf(indexVal < structType.numMembers,
						"%s: create_aggregate member index out of bounds, got %s, while union has %s members",
						instrIndex, indexVal, structType.numMembers);
					IrIndex value = instrHeader.arg(ir, 1);
					IrIndex argType = getValueType(value, ir, c);
					IrIndex memberType = structMembers[indexVal].type;
					bool sameType = c.types.isSameType(argType, memberType);
					c.assertf(sameType,
						"%s: create_aggregate argument type mismatch of %s member of %s. Expected %s, got %s",
						instrIndex, indexVal, IrIndexDump(vreg.type, c, ir), IrIndexDump(memberType, c, ir), IrIndexDump(argType, c, ir));
				}
				else
				{
					c.assertf(instrHeader.numArgs == structType.numMembers,
						"%s: create_aggregate invalid number of arguments, got %s, expected %s",
						instrIndex, instrHeader.numArgs, structType.numMembers);

					foreach (i, IrIndex arg; instrHeader.args(ir))
					{
						IrIndex memberType = structMembers[i].type;
						IrIndex argType = getValueType(arg, ir, c);
						bool sameType = c.types.isSameType(argType, memberType);
						c.assertf(sameType, "%s: create_aggregate type of arg %s mismatch. Expected %s, got %s",
							instrIndex, i+1, IrIndexDump(memberType, c, ir), IrIndexDump(argType, c, ir));
					}
				}
			}
			else if (vreg.type.isTypeArray)
			{
				IrTypeArray* arrayType = &c.types.get!IrTypeArray(vreg.type);
				c.assertf(instrHeader.numArgs == arrayType.numElements,
					"%s: create_aggregate invalid number of arguments, got %s, expected %s",
					instrIndex, instrHeader.numArgs, arrayType.numElements);

				IrIndex memberType = arrayType.elemType;
				foreach (i, IrIndex arg; instrHeader.args(ir))
				{
					IrIndex argType = getValueType(arg, ir, c);
					bool sameType = c.types.isSameType(argType, memberType);
					c.assertf(sameType, "%s: create_aggregate type of arg %s mismatch. Expected %s, got %s",
						instrIndex, i+1, IrIndexDump(memberType, c, ir), IrIndexDump(argType, c, ir));
				}
			}
			else
				c.assertf(false, "%s: create_aggregate result type must be struct or array, got %s",
						instrIndex, vreg.type.kind);
			break;

		default: break;
	}
}

void validateIrInstruction_dummy(CompilationContext* context, IrFunction* ir, IrIndex instrIndex, ref IrInstrHeader instrHeader)
{

}
