%option noyywrap
%option yylineno
%option c++
%x ORG OCT DEC BCD OPERAND TWOOPERANDS COMMA LABEL DEFINITION ENDLINE COMMENT

%{
	#include <math.h>
	#include <map>
	#include <fstream>
	#include <memory>
	#include <map>
	#include <vector>

	int prev;
	int pass = 1;
	int pc = 0;
	int col = 0;
	unsigned char ROM[65536];
	unsigned char opcode;
	int bits;
	std::string mnemonic;
	std::string id;
	std::string operandStr;
	int reg;

	int print2(const char *format, ...)
	{
		if ( pass == 2 )
		{
			va_list args;
			va_start(args, format);
			int ret = vprintf(format, args);
			va_end(args);
			return ret;
		}

		return 0;
	}

	class SymbolReference {
	public:
		SymbolReference(int b, int p, int l) :
			bits(b), pc(p), line(l)
		{
		}
		int bits;
		int pc;
		int line;
	};

	class SymbolTableEntry {
	public:
		SymbolTableEntry(const char *n, int val = 0, bool def = false) :
			bDefined(def),
			value(val),
			name(n)
		{
		}

		bool		bDefined;
		std::string	name;
		int			value;
		std::vector<SymbolReference> references;
	};

	typedef std::shared_ptr<SymbolTableEntry> SymbolPtr;
	std::map<std::string, SymbolPtr> SymbolTable;

	void listSymbols()
	{
		if ( pass == 1 ) return;
		puts("Symbol Table");
		for ( auto it = SymbolTable.begin(); it != SymbolTable.end(); ++it )
		{
			printf("%6s  %04o\n", it->first.c_str(), it->second->bDefined ? it->second->value : 07777);
		}
	}

	void listUndefined()
	{
		puts("\nUndefined Symbols");
		int n = 0;
		for ( auto it = SymbolTable.begin(); it != SymbolTable.end(); ++it )
		{
			if ( !it->second->bDefined )
			{
				++n;
				printf("%s:", it->first.c_str());
				int nRef = 0;
				for ( auto itr = it->second->references.begin();
					  itr != it->second->references.end();
					  ++itr )
				{
					printf(" %d", itr->line);
					++nRef;
					if ( nRef % 10 == 0 ) printf("\n\t");
				}
				putchar('\n');
			}
		}

		printf("%d undefined symbols\n", n);
	}

	void defineSymbol(const char *symbol, int line, int val)
	{
		std::string s(symbol);
		auto entry = SymbolTable.find(s);
		if ( entry == SymbolTable.end() )
		{
			entry = SymbolTable.insert(std::pair<std::string, SymbolPtr>(s, SymbolPtr(new SymbolTableEntry(symbol, val, true)))).first;
			//if ( pass == 1 ) printf("%4d: Added symbol %s (0x%03X)\n", line, symbol, val);
		}
		else if ( entry->second->bDefined )
		{
			// Multiple definition
			if ( pass == 1 )
				printf("%4d: Error - symbol %s multiply defined\n", line, symbol);
			else if ( entry->second->value != val )
				print2("%4d: Error - symbol %s has different value in pass 2! (0x%03X, 0x%03X)\n", line, symbol, entry->second->value, val);
		}
		else
		{
			// Define it
#ifdef DEBUG
			printf("%4d: Defined symbol %s (0x%03X)\n", line, symbol, val);
#endif
			entry->second->value = val;
			entry->second->bDefined = true;

			// Fill in references
			for ( auto it = entry->second->references.begin(); it != entry->second->references.end(); ++it )
			{
				if ( it->bits == 3 )
				{
					ROM[it->pc] |= (val & 0x07);
#ifdef DEBUG
					printf("Updated %03x to %02X\n", it->pc, ROM[it->pc]);
#endif
				}
				else if ( it->bits == 4 )
				{
					ROM[it->pc] |= (val & 0x0F);
#ifdef DEBUG
					printf("Updated %03x to %02X\n", it->pc, ROM[it->pc]);
#endif
				}
				else if ( it->bits == 8 || it->bits == 12 )
				{
					ROM[it->pc+1] = (val & 0xFF);
#ifdef DEBUG
					printf("Updated %03x to %02X\n", it->pc+1, ROM[it->pc+1]);
#endif
				}
				else if ( it->bits == 11 )
				{
					unsigned char opcode = ROM[it->pc];
					ROM[it->pc] = opcode | ((val >> 8) & 0x07);
#ifdef DEBUG
					printf("Updated %03x to %02X\n", it->pc, ROM[it->pc]);
#endif
					if ( opcode != 0x90 && opcode != 0x98 )
					{
						ROM[it->pc+1] = (val & 0xFF);
#ifdef DEBUG
						printf("Updated %03x to %02X\n", it->pc, ROM[it->pc]);
						printf("Updated %03x to %02X\n", it->pc+1, ROM[it->pc+1]);
#endif
					}
				}
			}
		}
	}

	int lookupSymbol(const char *symbol, int line, int bits, int pc)
	{
		//print2("lookupSymbol %s... ", symbol);
		std::string s(symbol);
		auto entry = SymbolTable.find(s);
		if ( entry == SymbolTable.end() )
		{
			print2("Symbol not found in pass 2: %s\n", symbol);
			entry = SymbolTable.insert(std::pair<std::string, SymbolPtr>(s, SymbolPtr(new SymbolTableEntry(symbol, 0, false)))).first;
		}
		//else print2("value: %03X\n", entry->second->value);

		if ( pass == 1 ) entry->second->references.push_back(SymbolReference(bits, pc, line));
		return entry->second->value;
	}

	void emitThreeBits(int b, int line, const char *operand)
	{
		if ( b < 0 || b >  7 )
		{
			print2("%4d: warning truncating operand to 3 bits %d\n", line, b);
			b &= 0x07;
		}
		ROM[pc] = opcode | b;
		//col = print2("%4d: %03X %02X    %6s %s %s", line, pc, ROM[pc], id.c_str(), mnemonic.c_str(), operand);
		col = print2("%4d: %04o %03o     %6s %s %s", line, pc, ROM[pc], id.c_str(), mnemonic.c_str(), operand);
		//	col = 24+strlen(operand);
		++pc;
	}

	void emitFourBits(int r, int line, const char *operand)
	{
		if ( r < 0 || r > 15 )
		{
			print2("%4d: warning truncating operand to 4 bits %d\n", line, r);
			r &= 0x0F;
		}
		ROM[pc] = opcode | r;
		//col = print2("%4d: %03X %02X    %6s %s %s", line, pc, ROM[pc], id.c_str(), mnemonic.c_str(), operand);
		col = print2("%4d: %04o %03o     %6s %s %s", line, pc, ROM[pc], id.c_str(), mnemonic.c_str(), operand);
		//	col = 24+strlen(operand);
		++pc;
	}

	void emitEightBits(int r, int line, const char *operand)
	{
		if ( r < 0 || r > 255 )
		{
			print2("%4d: warning truncating operand to 8 bits %d\n", line, r);
			r &= 0xFF;
		}
		ROM[pc] = opcode;
		ROM[pc+1] = r;
		//col = print2("%4d: %03X %02X %02X %6s %s %s", line, pc, opcode, r, id.c_str(), mnemonic.c_str(), operand);
		col = print2("%4d: %04o %03o %03o %6s %s %s", line, pc, opcode, r, id.c_str(), mnemonic.c_str(), operand);
		// 	col = 24+strlen(operand);
		pc += 2;
	}

	void emitElevenBits(int addr, int line, const char *operand)
	{
		if ( addr < 0 || addr > 2047 )
		{
			print2("%4d: warning truncating operand to 11 bits %d", line, addr);
			addr &= 0x7FF;
		}
		ROM[pc] = opcode | (addr>>8);
		if ( opcode == 0x90 || opcode == 0x98 )
		{
			//col = print2("%4d: %03X %02X    %6s %s %s", line, pc, ROM[pc], id.c_str(), mnemonic.c_str(), operand);
			col = print2("%4d: %04o %03o     %6s %s %s", line, pc, ROM[pc], id.c_str(), mnemonic.c_str(), operand);
			++pc;
		}
		else
		{ 
			ROM[pc+1] = addr & 0xFF;
			//col = print2("%4d: %03X %02X %02X %6s %s %s", line, pc, ROM[pc], ROM[pc+1], id.c_str(), mnemonic.c_str(), operand);
			col = print2("%4d: %04o %03o %03o %6s %s %s", line, pc, ROM[pc], ROM[pc+1], id.c_str(), mnemonic.c_str(), operand);
			pc += 2;
		}
		//	col = 24+strlen(operand);
	}

	void emitTwelveBits(int r, int val, int line, const char *operand)
	{
		if ( r < 0 || r > 15 )
		{
			print2("%4d: warning truncating register to 4 bits %d\n", line, r);
			r &= 0x0F;
		}
		ROM[pc] = opcode | r;
		if ( val < 0 || val > 255 )
		{
			print2("%4d: warning truncating operand to 8 bits %d\n", line, val);
			val &= 0xFF;
		}
		ROM[pc+1] = val;
		//col = print2("%4d: %03X %02X %02X %6s %s %s", line, pc, ROM[pc], ROM[pc+1], id.c_str(), mnemonic.c_str(), operand);
		col = print2("%4d: %04o %03o %03o %6s %s %s", line, pc, ROM[pc], ROM[pc+1], id.c_str(), mnemonic.c_str(), operand);
		//	col = 24+strlen(operand);
		pc += 2;
	}

	void emit(int value, int lineno, const char *text)
	{
		switch ( bits )
		{
			case 3:
				emitThreeBits(value, lineno, text);
				break;
			case 4:
				emitFourBits(value, lineno, text);
				break;
			case 8:
				emitEightBits(value, lineno, text);
				break;
			case 11:
				emitElevenBits(value, lineno, text);
				break;
			case 12:
				operandStr += text;
				emitTwelveBits(reg, value, lineno, operandStr.c_str());
				break;
		}
		id.clear();
		mnemonic.clear();
	}

	void startInstruction(int line)
	{
		if ( !id.empty() )
		{
		 	defineSymbol(id.c_str(), line, pc);
		}
		else id = "      ";
		col = 6;
	}

	void emitInstruction(int line, char *mnemonic, unsigned char opcode)
	{
		startInstruction(line);
		ROM[pc] = opcode;
		//col = print2("%4d: %03X %02X    %6s %s", line, pc, opcode, id.c_str(), mnemonic);
		col = print2("%4d: %04o %03o     %6s %s", line, pc, opcode, id.c_str(), mnemonic);
		id.clear();
		//	col = 23;
		++pc;
	}

	void syntaxError(const char *msg, int col)
	{
		while ( col-- ) putchar(' ');
		printf("^Syntax Error: %s\n", msg);
	}
%}
     
OCTDIGIT [0-7]
DECDIGIT [0-9]
HEXDIGIT [0-9a-fA-F]
ID       [_A-Za-z][_A-Za-z0-9]*
     
%%

<OPERAND>[ \t]	/* ignore space */
<OPERAND>0x{HEXDIGIT}+ {
	int b = strtol(yytext+2, NULL, 16);
	emit(b, yylineno, yytext);
	BEGIN(ENDLINE);
}
<OPERAND>{OCTDIGIT}+ {
	int b = strtol(yytext, NULL, 8);
	emit(b, yylineno, yytext);
	BEGIN(ENDLINE);
}
<OPERAND>{DECDIGIT}+ {
	print2("%4d: %s %s", yylineno, mnemonic.c_str(), yytext);
	int c;
   	while((c = yyinput()) != 0)
   	{
		if ( c == ':' ) c = '\n';
		if ( pass == 2 ) putchar(c);
   		if(c == '\n')
		{
			break;
		}
	}
	if ( pass == 2 ) syntaxError("bad octal operand", 6+mnemonic.size());
	id.clear();
	mnemonic.clear();
	BEGIN(INITIAL);
}
<OPERAND>{ID} {
	int val = lookupSymbol(yytext, yylineno, bits, pc);
	emit(val, yylineno, yytext);
	BEGIN(ENDLINE);
}
<OPERAND>[\n] {
	print2("%4d %s\n", yylineno-1, mnemonic.c_str());
	if ( pass == 2 ) syntaxError("missing operand", 6+mnemonic.size());
	id.clear();
	mnemonic.clear();
	BEGIN(INITIAL);
}

<TWOOPERANDS>[ \t]
<TWOOPERANDS>0x{HEXDIGIT}+ {
	operandStr = yytext;
	reg = strtol(yytext+2, NULL, 16);
	BEGIN(COMMA);
}
<TWOOPERANDS>{OCTDIGIT}+ {
	operandStr = yytext;
	reg = strtol(yytext, NULL, 8);
	BEGIN(COMMA);
}
<TWOOPERANDS>{ID} {
	operandStr = yytext;
	reg = lookupSymbol(yytext, yylineno, 4, pc);
	BEGIN(COMMA);
}
<TWOOPERANDS,COMMA>\n {
	print2("%4d: Invalid %s instruction\n", yylineno, mnemonic.c_str());
	id.clear();
	mnemonic.clear();
	BEGIN(INITIAL);
}

<COMMA>[ \t]*, {
	operandStr += ",";
	BEGIN(OPERAND);
}

<LABEL>[ \t]
<LABEL>= {
	mnemonic = yytext;
	BEGIN(DEFINITION);
}
<LABEL>\n {
	// Put in symbol table by pretending there will be an instruction
	startInstruction(yylineno);
	//print2("%4d: %03X       %s\n", yylineno, pc, id.c_str());
	print2("%4d: %04o         %s\n", yylineno, pc, id.c_str());
	id.clear();
	BEGIN(INITIAL);
}
<INITIAL>ORG {
	id = "";
	mnemonic = yytext;
	BEGIN(ORG);
}
<LABEL>ORG {
	mnemonic = yytext;
	BEGIN(ORG);
}
<LABEL>OCT {
	mnemonic = yytext;
	BEGIN(OCT);
}
<LABEL>DEC {
	mnemonic = yytext;
	BEGIN(DEC);
}
<LABEL>BCD {
	mnemonic = yytext;
	BEGIN(BCD);
}

<DEFINITION,ORG,OCT,DEC,BCD>[ \t] /* ignore space */
<DEFINITION,ORG>0x{HEXDIGIT}+ {
	int val = strtol(yytext+2, NULL, 16);
	if ( YY_START == ORG )
	{
		pc = val & 0x7FF;
	}
	if ( !id.empty() ) defineSymbol(id.c_str(), yylineno, val);
	//col = print2("%4d:           %6s %s 0x%03X", yylineno, id.c_str(), mnemonic.c_str(), val);
	col = print2("%4d:              %6s %s %04o", yylineno, id.c_str(), mnemonic.c_str(), val);
	//	col = 25+mnemonic.size();
	id.clear();
	mnemonic.clear();
	BEGIN(ENDLINE);
}
<DEFINITION,ORG,OCT>{OCTDIGIT}+ {
	int val = strtol(yytext, NULL, 8);
	if ( YY_START == ORG )
	{
		pc = val & 0x7FF; 
	}
	if (!id.empty()) defineSymbol(id.c_str(), yylineno, val);
	//col = print2("%4d:           %6s %s 0x%03X", yylineno, id.c_str(), mnemonic.c_str(), val);
	col = print2("%4d:              %6s %s %04o", yylineno, id.c_str(), mnemonic.c_str(), val);
	//	col = 25+mnemonic.size();
	id.clear();
	mnemonic.clear();
	BEGIN(ENDLINE);
}
<DEFINITION,ORG>{ID} {
	int val = lookupSymbol(yytext, yylineno, 11, pc);
	if ( YY_START == ORG )
	{
		pc = val & 0x7FF;
	}
	if ( !id.empty() ) defineSymbol(id.c_str(), yylineno, val);
	col = print2("%4d:           %6s %s %d", yylineno, id.c_str(), mnemonic.c_str(), val);
	//	col = 25+mnemonic.size();
	id.clear();
	mnemonic.clear();
	BEGIN(ENDLINE);
}
<OCT>{DECDIGIT}+ {
	print2("%4d: %6s OCT %s", yylineno, id.c_str(), yytext);
	int c;
   	while((c = yyinput()) != 0)
   	{
		if ( c == ':' ) c = '\n';
		if ( pass == 2 ) putchar(c);
   		if(c == '\n')
		{
			break;
		}
	}
	if ( pass == 2 ) syntaxError("bad octal value", 10+id.size());
	id.clear();
	mnemonic.clear();
	BEGIN(INITIAL);
}
<DEC>{DECDIGIT}+ {
	int val = atoi(yytext);
	if ( !id.empty() ) defineSymbol(id.c_str(), yylineno, val);
	col = print2("%4d:              %6s %s %d", yylineno, id.c_str(), mnemonic.c_str(), val);
	id.clear();
	mnemonic.clear();
	BEGIN(ENDLINE);
}
<BCD>{DECDIGIT}+ {
	int val = 0;
	char *p = yytext;
	while ( *p )
	{
		char c = *p++;
		val <<= 4;
		val |= (c-'0');
	}
	defineSymbol(id.c_str(), yylineno, val);
	col = print2("%4d:              %6s BCD %X", yylineno, id.c_str(), val);
	id.clear();
	mnemonic.clear();
	BEGIN(ENDLINE);
}
<DEFINITION,ORG,OCT,DEC,BCD>\n {
	if (pass == 2)
	{
		printf("%4d: %s %s\n", yylineno, id.c_str(), mnemonic.c_str());
		int chars = 6+id.size()+mnemonic.size();
		syntaxError("invalid definition", chars);
	}
	id.clear();
	mnemonic.clear();
	BEGIN(INITIAL);
}

{DECDIGIT}+ {
	print2("An integer: %s (%d)\n", yytext,
	atoi( yytext ) );
}

<INITIAL,LABEL>INB { emitInstruction(yylineno, yytext, 0x00); BEGIN(ENDLINE); }
<INITIAL,LABEL>DEB { emitInstruction(yylineno, yytext, 0x01); BEGIN(ENDLINE); }
<INITIAL,LABEL>IND { emitInstruction(yylineno, yytext, 0x02); BEGIN(ENDLINE); }
<INITIAL,LABEL>DED { emitInstruction(yylineno, yytext, 0x03); BEGIN(ENDLINE); }
<INITIAL,LABEL>CLA { emitInstruction(yylineno, yytext, 0x04); BEGIN(ENDLINE); }
<INITIAL,LABEL>CMA { emitInstruction(yylineno, yytext, 0x05); BEGIN(ENDLINE); }
<INITIAL,LABEL>RSA { emitInstruction(yylineno, yytext, 0x06); BEGIN(ENDLINE); }
<INITIAL,LABEL>LSA { emitInstruction(yylineno, yytext, 0x07); BEGIN(ENDLINE); }
<INITIAL,LABEL>SGT { emitInstruction(yylineno, yytext, 0x08); BEGIN(ENDLINE); }
<INITIAL,LABEL>SLT { emitInstruction(yylineno, yytext, 0x09); BEGIN(ENDLINE); }
<INITIAL,LABEL>SEQ { emitInstruction(yylineno, yytext, 0x0A); BEGIN(ENDLINE); }
<INITIAL,LABEL>SAZ { emitInstruction(yylineno, yytext, 0x0B); BEGIN(ENDLINE); }
<INITIAL,LABEL>SLE { emitInstruction(yylineno, yytext, 0x0C); BEGIN(ENDLINE); }
<INITIAL,LABEL>SGE { emitInstruction(yylineno, yytext, 0x0D); BEGIN(ENDLINE); }
<INITIAL,LABEL>SNE { emitInstruction(yylineno, yytext, 0x0E); BEGIN(ENDLINE); }
<INITIAL,LABEL>SAN { emitInstruction(yylineno, yytext, 0x0F); BEGIN(ENDLINE); }
<INITIAL,LABEL>SES { emitInstruction(yylineno, yytext, 0x1F); BEGIN(ENDLINE); }
<INITIAL,LABEL>ENI { emitInstruction(yylineno, yytext, 0x2F); BEGIN(ENDLINE); }
<INITIAL,LABEL>SEZ { emitInstruction(yylineno, yytext, 0x3F); BEGIN(ENDLINE); }
<INITIAL,LABEL>NOP { emitInstruction(yylineno, yytext, 0x5F); BEGIN(ENDLINE); }
<INITIAL,LABEL>DSI { emitInstruction(yylineno, yytext, 0xAF); BEGIN(ENDLINE); }
<INITIAL,LABEL>RTI { emitInstruction(yylineno, yytext, 0xB0); BEGIN(ENDLINE); }
<INITIAL,LABEL>RTE { emitInstruction(yylineno, yytext, 0xB1); BEGIN(ENDLINE); }
<INITIAL,LABEL>STE { emitInstruction(yylineno, yytext, 0xB4); BEGIN(ENDLINE); }
<INITIAL,LABEL>CLE { emitInstruction(yylineno, yytext, 0xB5); BEGIN(ENDLINE); }
<INITIAL,LABEL>RTS { emitInstruction(yylineno, yytext, 0xB8); BEGIN(ENDLINE); }
<INITIAL,LABEL>RSE { emitInstruction(yylineno, yytext, 0xB9); BEGIN(ENDLINE); }


<INITIAL,LABEL>LDR {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0xCF;
	bits = 8;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>SBS {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x10;
	bits = 3;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>SBZ {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x30;
	bits = 3;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>SBN {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x20;
	bits = 3;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>CBN {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0xA0;
	bits = 3;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>INA {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x40;
	bits = 4;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>OTA {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x50;
	bits = 4;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>OTR {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0xC0;
	bits = 12;
	BEGIN(TWOOPERANDS);
}

<INITIAL,LABEL>STC {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x28;
	bits = 3;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>CLC {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0xA8;
	bits = 3;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>SFS {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x18;
	bits = 3;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>SFZ {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x38;
	bits = 3;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>JAI {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x90;
	//bits = 11;
	bits = 3;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>JAS {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x98;
	//bits = 11;
	bits = 3;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>JMP {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x80;
	bits = 11;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>JSB {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x88;
	bits = 11;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>LDA {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x60;
	bits = 4;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>STA {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0x70;
	bits = 4;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>LDI {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0xE0;
	bits = 4;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>STI {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0xF0;
	bits = 4;
	BEGIN(OPERAND);
}

<INITIAL,LABEL>STR {
	startInstruction(yylineno);
	mnemonic = yytext;
	opcode = 0xD0;
	bits = 12;
	BEGIN(TWOOPERANDS);
}

<INITIAL,LABEL>END {
	startInstruction(yylineno);
	mnemonic = yytext;
	if ( pass == 2 )
	{
		const char *fileName = "nano.bin";
		printf("%4d: %04o         %6s %s\n", yylineno, pc, id.c_str(), mnemonic.c_str());

		FILE *f = fopen(fileName, "w");
		if ( f == NULL )
		{
			printf("Failed to open '%s' for writing\n", fileName);
		}
		else
		{
			fwrite(ROM, pc, 1, f);
			printf("Writing %d bytes to %s\n", pc, fileName);
		}
	}
	BEGIN(ENDLINE);
}

EOF {
	yyterminate();
}

0x{HEXDIGIT}+ {
	print2("%4d: A hex number: %s\n", yylineno, yytext);
}

{ID} {
	id = yytext;
	BEGIN(LABEL);
}
 
[ \t\r]+ /* whitespace */
[\n] if ( pass == 2 ) printf("%4d:\n", yylineno-1);

"/*" {
	if ( pass == 2 ) ECHO;
	prev = YY_START;
	BEGIN(COMMENT);
}
<COMMENT>[^*\n]* if (pass == 2) ECHO;	/* anything thats not '*' or '\n' */
<COMMENT>"*"+[^*/\n]* if (pass == 2) ECHO;/* '*' followed by anything but '*', '/' or '\n' */
<COMMENT>\n if (pass == 2) ECHO;
<COMMENT>"*"+"/" {
	if (pass == 2) ECHO;
	BEGIN(prev == INITIAL ? ENDLINE : prev);	/* any number of '*'s followed by '/' */
}

<ENDLINE>"/*" {
	if ( pass == 2 ) ECHO;
	BEGIN(COMMENT);	/* Ignore remainder of line, but handle comments properly */
}
<ENDLINE>":" {
	if ( pass == 2 ) putchar('\n');
	BEGIN(INITIAL);
}
<ENDLINE>\n {
	if ( pass == 2 ) ECHO;
	BEGIN(INITIAL);
}
<ENDLINE>[ \t]
<ENDLINE>[^*:\n] {
	if ( pass == 2 )
	{
		ECHO;
	}
}

<*>"//"|"*" {	/* Single line comments */
	if ( YY_START != INITIAL && YY_START != ENDLINE )
	{
		int chars = 0;
		if (pass == 2)
		{
			print2("%4d: %s %s %s", yylineno, id.c_str(), mnemonic.c_str(), yytext);
			chars = 7+id.size()+mnemonic.size();
		}
		int c;
   		while((c = yyinput()) != 0)
   		{
			if ( c == ':' ) c = '\n';
			if ( pass == 2 ) putchar(c);
       		if(c == '\n')
			{
				break;
			}
		}
		if (pass == 2)
		{
			syntaxError("unexpected", chars);
		}
		id.clear();
		mnemonic.clear();
		BEGIN(INITIAL);
	} 
	else
	{
		if (pass == 2 )
		{
			if ( YY_START == INITIAL )
			{
				printf("%4d: ", yylineno);
				col = 5;
			}
			while ( col++ < 40 ) putchar(' ');
			ECHO;
		}
		int c;
   		while((c = yyinput()) != 0)
   		{
			if ( c == ':' ) c = '\n';
			if ( pass == 2 ) putchar(c);
       		if(c == '\n')
			{
				break;
			}
		}
		BEGIN(INITIAL);
	}
}

.	print2( "Unrecognized character: %s\n", yytext );
     
%%
     

int main( int argc, char **argv )
{
	++argv, --argc;  /* skip over program name */
#if 0
	if ( argc > 0 )
		yyin = fopen( argv[0], "r" );
	else
		yyin = stdin;
     
	yylex();
#else
	FlexLexer* lexer;
	if ( argc > 0 )
	{
		for (pass = 1; pass <= 2; ++pass )
		{
			listSymbols();
			lexer = new yyFlexLexer(new std::fstream(argv[0], std::ios::in));
		
			pc = 0;
    		while(lexer->yylex() != 0)
    			;

			delete lexer;
		}
		listUndefined();
	}
#endif
}

