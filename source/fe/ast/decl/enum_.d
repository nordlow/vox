/// Copyright: Copyright (c) 2017-2019 Andrey Penechko.
/// License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
/// Authors: Andrey Penechko.
module fe.ast.decl.enum_;

import all;
import fe.ast.ast_index;

@(AstType.decl_enum)
struct EnumDeclaration
{
	mixin ScopeDeclNodeData!(AstType.decl_enum, AstFlags.isType);
	AstIndex parentScope;
	AstIndex memberScope;
	AstIndex memberType;
	Identifier id;

	private enum Flags
	{
		isAnonymous = AstFlags.userFlag
	}

	this(TokenIndex loc, AstIndex parentScope, AstIndex memberScope, AstNodes members, AstIndex memberType, Identifier id)
	{
		this.loc = loc;
		this.astType = AstType.decl_enum;
		this.flags = AstFlags.isType | AstFlags.isDeclaration;
		this.parentScope = parentScope;
		this.memberScope = memberScope;
		this.declarations = members;
		this.memberType = memberType;
		this.id = id;
	}

	/// Anonymous
	this(TokenIndex loc, AstIndex parentScope, AstIndex memberScope, AstNodes members, AstIndex memberType)
	{
		this.loc = loc;
		this.astType = AstType.decl_enum;
		this.flags = AstFlags.isDeclaration | Flags.isAnonymous;
		this.parentScope = parentScope;
		this.memberScope = memberScope;
		this.declarations = members;
		this.memberType = memberType;
	}

	bool isAnonymous() { return cast(bool)(flags & Flags.isAnonymous); }
	SizeAndAlignment sizealign(CompilationContext* c) {
		c.assertf(!isAnonymous, loc, "Anonymous enums are not a type");
		c.assertf(memberType.isDefined, loc, "Enum has no member type");
		return typeSizealign(memberType, c);
	}
}

void print_enum(EnumDeclaration* node, ref AstPrintState state)
{
	if (node.isAnonymous)
		state.print("ENUM ", node.memberType.printer(state.context));
	else
		state.print("ENUM ", node.memberType.printer(state.context), " ", state.context.idString(node.id));
	print_ast(node.declarations, state);
}

void post_clone_enum(EnumDeclaration* node, ref CloneState state)
{
	state.fixScope(node.parentScope);
	state.fixScope(node.memberScope);
	state.fixAstIndex(node.memberType);
	state.fixAstNodes(node.declarations);
}

void name_register_self_enum(AstIndex nodeIndex, EnumDeclaration* node, ref NameRegisterState state) {
	node.state = AstNodeState.name_register_self;
	if (!node.isAnonymous) node.parentScope.insert_scope(node.id, nodeIndex, state.context);
	node.state = AstNodeState.name_register_self_done;
}

void name_register_nested_enum(AstIndex nodeIndex, EnumDeclaration* node, ref NameRegisterState state) {
	node.state = AstNodeState.name_register_nested;
	require_name_register(node.memberType, state);
	require_name_register(node.declarations, state);
	node.state = AstNodeState.name_register_nested_done;
}

void name_resolve_enum(EnumDeclaration* node, ref NameResolveState state) {
	node.state = AstNodeState.name_resolve;
	require_name_resolve(node.memberType, state);
	require_name_resolve(node.declarations, state);
	node.state = AstNodeState.name_resolve_done;
}

void type_check_enum(EnumDeclaration* node, ref TypeCheckState state)
{
	node.state = AstNodeState.type_check;
	require_type_check(node.memberType, state);
	require_type_check(node.declarations, state);
	node.state = AstNodeState.type_check_done;
}

IrIndex gen_ir_type_enum(EnumDeclaration* node, CompilationContext* context)
{
	return gen_ir_type(node.memberType, context);
}

IrIndex gen_default_value_enum(EnumDeclaration* node, CompilationContext* c)
{
	c.assertf(node.declarations.length > 0, node.loc, "Enum %s has no members", c.idString(node.id));
	return node.declarations[0].get!EnumMemberDecl(c).getInitVal(c);
}

@(AstType.decl_enum_member)
struct EnumMemberDecl
{
	mixin AstNodeData!(AstType.decl_enum_member, AstFlags.isDeclaration | AstFlags.isStatement);
	AstIndex parentScope;
	AstIndex type;
	AstIndex initializer;
	Identifier id;
	ushort scopeIndex;
	IrIndex initValue; // cached value of initializer, calculated in type check

	IrIndex getInitVal(CompilationContext* c) {
		c.assertf(initValue.isDefined, loc, "Enum member value is undefined");
		return initValue;
	}
}

void print_enum_member(EnumMemberDecl* node, ref AstPrintState state)
{
	state.print("ENUM MEMBER ", node.type.printer(state.context), " ", state.context.idString(node.id));
	if (node.initializer) print_ast(node.initializer, state);
}

void post_clone_enum_member(EnumMemberDecl* node, ref CloneState state)
{
	state.fixScope(node.parentScope);
	state.fixAstIndex(node.type);
	state.fixAstIndex(node.initializer);
}

void name_register_self_enum_member(AstIndex nodeIndex, EnumMemberDecl* node, ref NameRegisterState state) {
	node.state = AstNodeState.name_register_self;
	node.parentScope.insert_scope(node.id, nodeIndex, state.context);
	node.state = AstNodeState.name_register_self_done;
}

void name_register_nested_enum_member(AstIndex nodeIndex, EnumMemberDecl* node, ref NameRegisterState state) {
	CompilationContext* c = state.context;
	node.state = AstNodeState.name_register_nested;
	if (node.type) {
		auto type = node.type.get_node(c);
		if (type.astType == AstType.decl_enum) {
			require_name_register(type.as!EnumDeclaration(c).memberType, state);
		} else require_name_register(node.type, state);
	}
	if (node.initializer) require_name_register(node.initializer, state);
	node.state = AstNodeState.name_register_nested_done;
}

void name_resolve_enum_member(EnumMemberDecl* node, ref NameResolveState state) {
	CompilationContext* c = state.context;
	node.state = AstNodeState.name_resolve;
	if (node.type) {
		auto type = node.type.get_node(c);
		if (type.astType == AstType.decl_enum) {
			require_name_resolve(type.as!EnumDeclaration(c).memberType, state);
		} else require_name_resolve(node.type, state);
	}
	if (node.initializer) require_name_resolve(node.initializer, state);
	node.state = AstNodeState.name_resolve_done;
}

void type_check_enum_member(EnumMemberDecl* node, ref TypeCheckState state)
{
	CompilationContext* c = state.context;
	node.state = AstNodeState.type_check;
	if (node.initializer) {
		if (node.type) {
			auto type = node.type.get_node(c);
			if (type.astType == AstType.decl_enum) {
				require_type_check(type.as!EnumDeclaration(c).memberType, state);
			} else require_type_check(node.type, state);
			require_type_check_expr(node.type, node.initializer, state);
			//writefln("  autoconvTo %s", printer(node.type, c));
			TypeConvResKind res = checkTypeConversion(node.initializer.get_expr_type(c), node.type, node.initializer, c);
			if (res.successful) {
				insertCast(node.initializer, node.type, res, c);
				if (node.initializer.get_expr_type(c) != CommonAstNodes.type_error)
					node.initValue = eval_static_expr(node.initializer, c);
			} else {
				c.error(node.initializer.loc(c),
					"Cannot convert expression of type `%s` to `%s`",
					node.initializer.get_expr_type(c).printer(c),
					node.type.printer(c));
			}
		} else {
			require_type_check(node.initializer, state);
			node.type = get_expr_type(node.initializer, c);
			node.initValue = eval_static_expr(node.initializer, c);
		}
	}
	node.state = AstNodeState.type_check_done;
}
