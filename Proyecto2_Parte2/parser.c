/* =============================================================================
 *  PROYECTO 2, PARTE 2  -  ANALIZADOR SINTÁCTICO DESCENDENTE RECURSIVO
 *
 *  Materia:  Compiladores
 *  Equipo:   Baños Monjaraz José Guadalupe
 *            Castañeda Carrasco Luisa Valentina
 *            Solis Espinosa Pedro Alberto
 *
 *  Qué hace:
 *    Recibe la secuencia de átomos que generó el analizador léxico y revisa
 *    que cumpla la gramática LL(1) del lenguaje X. Hay una función por cada
 *    no terminal (42 en total). Cada función mira el átomo actual (variable c)
 *    y elige la regla cuyo conjunto selección lo contiene; los conjuntos son
 *    los que se calcularon en la parte 1 del proyecto y aparecen en el
 *    comentario de cada caso.
 *
 *  Cambios respecto de la gramática de la parte 1:
 *    - Regla 72: <listas> se toma como <listaS> (ya se había hecho en la parte 1).
 *    - Regla 80: <opCad> -> & <expCad> en lugar de <opCad> -> h <expCad>.
 *      En la tabla del Anexo A el operador de cadenas & produce el átomo &,
 *      y h es el átomo de &&. Con el cambio la gramática sigue siendo LL(1):
 *      SEL(79) = { l }, SEL(80) = { & }, SEL(81) = { } }.
 *
 *  Manejo de errores (recuperación sencilla en modo pánico):
 *    1. consumir(x): si el átomo actual es x lo consume; si no, informa
 *       "se esperaba x". Si el átomo siguiente es x, el actual sobra: lo
 *       salta y consume x. Si no, NO avanza, como si x hubiera estado ahí.
 *       Así un símbolo faltante o uno de más (por ejemplo un ';') produce
 *       un solo error.
 *    2. Si una función no encuentra el átomo actual en ningún conjunto
 *       selección de sus reglas, informa el error y salta átomos hasta uno
 *       del SIGUIENTE de su no terminal o hasta un delimitador ( ; # } ) ).
 *    3. En los no terminales que derivan ξ y no forman listas de sentencias
 *       o declaraciones (E', T', <expLog>, <opCad>, <valorIni>, <listaVar>,
 *       <valRet>, <listP> y <Param>) la regla ξ se usa por omisión: si el
 *       átomo no está en ningún conjunto selección, la función no consume
 *       nada y el error lo informa quien esperaba el símbolo siguiente, con
 *       un mensaje más claro ("se esperaba ';'"). Esto retrasa la detección
 *       pero no deja pasar ningún error (Aho et al., 2007, sección 4.4.5).
 *    4. Las funciones de listas (otraFunc, listDecl, listaS y casos) saltan
 *       hasta un átomo con el que la lista puede continuar y lo vuelven a
 *       intentar, para seguir revisando el resto del archivo.
 *    5. Dos casos frecuentes tienen un mensaje propio: una declaración
 *       escrita después de las sentencias (listaS) y algo que no es una
 *       función fuera de las funciones, como una variable global (Func).
 *    6. Después de un error no se informa otro hasta que se consuma algún
 *       átomo correctamente; así un solo error no genera mensajes en cascada.
 *    7. El análisis siempre termina: una lista solo se repite cuando el
 *       átomo actual está en uno de sus conjuntos selección (y entonces se
 *       consume o se toma ξ), y saltar átomos se detiene en el $.
 * ============================================================================= */

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "parser.h"

/* -----------------------------------------------------------------------------
 *  Estado del analizador
 * -------------------------------------------------------------------------- */
static const Atomo *atomos;          /* secuencia que termina con $            */
static int          total;           /* cantidad de átomos, incluido el $      */
static int          pos;             /* posición del átomo actual              */
static char         c;               /* átomo actual: atomos[pos].simbolo      */
static int          errores;         /* errores sintácticos informados         */
static int          en_recuperacion; /* 1 después de un error, hasta consumir  */
static FILE        *bitacora;        /* errores.txt, o NULL                    */

/* -----------------------------------------------------------------------------
 *  Funciones de apoyo
 * -------------------------------------------------------------------------- */
static void avanzar(void);
static void consumir(char esperado);
static void error_sintactico(const char *esperado);
static void informar_error(const char *esperado, int con_anterior);
static void sincronizar(const char *conjunto);
static void sincronizar_lista(const char *conjunto);
static void escribir_lexema(const Atomo *atomo, char *destino, size_t tam);
static const char *nombre_terminal(char t);
static void reportar(const char *formato, ...);

/* Átomos que cierran una sentencia, un bloque o una condición. Al saltar
   átomos después de un error, sincronizar() también se detiene en ellos. */
#define DELIMITADORES ";#})"

/* -----------------------------------------------------------------------------
 *  Una función por cada no terminal. E' y T' se llaman Ep y Tp porque C no
 *  admite el apóstrofo en un nombre.
 * -------------------------------------------------------------------------- */
/* Bloque 1: programa, funciones y declaraciones (reglas 1 a 22) */
static void Program(void);
static void otraFunc(void);
static void Func(void);
static void TipoF(void);
static void listArg(void);
static void otroArg(void);
static void Cuerpo(void);
static void listDecl(void);
static void Decl(void);
static void Tipo(void);
static void valorIni(void);
static void listaVar(void);
static void tipoVal(void);

/* Bloque 2: expresiones (reglas 23 a 49, 61 a 68, 77 a 81 y 87 a 92) */
static void Asig(void);
static void opArit(void);
static void E(void);
static void Ep(void);
static void T(void);
static void Tp(void);
static void F(void);
static void R(void);
static void opRel(void);
static void expLogica(void);
static void expLog(void);
static void expRel(void);
static void opLog(void);
static void expCad(void);
static void opCad(void);
static void Llama(void);
static void listP(void);
static void Param(void);

/* Bloque 3: sentencias (reglas 50 a 60, 69 a 76 y 82 a 86) */
static void Sent(void);
static void listaS(void);
static void Enq(void);
static void Se(void);
static void Q(void);
static void Faz(void);
static void Ret(void);
static void valRet(void);
static void Para(void);
static void Trocar(void);
static void casos(void);


/* =============================================================================
 *  analizar_sintaxis: punto de entrada. Toma el primer átomo, llama a la
 *  función del símbolo inicial <Program> y al final comprueba que se haya
 *  llegado al fin de la entrada.
 * ========================================================================== */
int analizar_sintaxis(const Atomo *lista, int cantidad, FILE *archivo)
{
    atomos          = lista;
    total           = cantidad;
    pos             = 0;
    errores         = 0;
    en_recuperacion = 0;
    bitacora        = archivo;
    c               = (total > 0) ? atomos[0].simbolo : FIN_DE_ENTRADA;

    Program();

    if (c != FIN_DE_ENTRADA)
        error_sintactico("el fin del archivo");

    return errores;
}


/* =============================================================================
 *  BLOQUE 1: programa, funciones y declaraciones (reglas 1 a 22)
 * ========================================================================== */

/* Regla 1: <Program> -> <Func> <otraFunc>                SEL = { f i g } */
static void Program(void)
{
    Func();
    otraFunc();
}

/* Reglas 2 y 3: <otraFunc> -> <Func> <otraFunc> | ξ */
static void otraFunc(void)
{
    switch (c) {
    case 'f': case 'i': case 'g':           /* regla 2, SEL = { f i g } */
        Func();
        otraFunc();
        break;
    case FIN_DE_ENTRADA:                    /* regla 3, SEL = { $ } */
        break;
    default:
        error_sintactico("otra funcion (flutuador, inteiro o assinado) o el fin del archivo");
        sincronizar_lista("fig");           /* el inicio de la siguiente función */
        if (c != FIN_DE_ENTRADA)
            otraFunc();
    }
}

/* Regla 4: <Func> -> <TipoF> a ( <listArg> ) { <Cuerpo> }    SEL = { f i g } */
static void Func(void)
{
    TipoF();
    consumir('a');
    if (c == '=' || c == ',' || c == ';') {
        /* Una variable declarada fuera de las funciones. Se informa, se salta
           hasta el ';' que termina la declaración y se sigue con la siguiente
           función. */
        error_sintactico("'(' (fuera de las funciones solo puede haber funciones)");
        sincronizar_lista(";");
        consumir(';');
        return;
    }
    consumir('(');
    listArg();
    consumir(')');
    consumir('{');
    Cuerpo();
    consumir('}');
}

/* Reglas 5 y 6: <TipoF> -> <Tipo> | g */
static void TipoF(void)
{
    switch (c) {
    case 'f': case 'i':                     /* regla 5, SEL = { f i } */
        Tipo();
        break;
    case 'g':                               /* regla 6, SEL = { g } */
        consumir('g');
        break;
    default:
        error_sintactico("el tipo de la funcion (flutuador, inteiro o assinado)");
        sincronizar("a");                   /* SIG(<TipoF>) */
    }
}

/* Reglas 7 y 8: <listArg> -> <Tipo> a <otroArg> | ξ */
static void listArg(void)
{
    switch (c) {
    case 'f': case 'i':                     /* regla 7, SEL = { f i } */
        Tipo();
        consumir('a');
        otroArg();
        break;
    case ')':                               /* regla 8, SEL = { ) } */
        break;
    default:
        error_sintactico("un tipo (flutuador o inteiro) o ')'");
        sincronizar(")");                   /* SIG(<listArg>) */
    }
}

/* Reglas 9 y 10: <otroArg> -> , <Tipo> a <otroArg> | ξ */
static void otroArg(void)
{
    switch (c) {
    case ',':                               /* regla 9, SEL = { , } */
        consumir(',');
        Tipo();
        consumir('a');
        otroArg();
        break;
    case ')':                               /* regla 10, SEL = { ) } */
        break;
    default:
        error_sintactico("',' o ')'");
        sincronizar(")");                   /* SIG(<otroArg>) */
    }
}

/* Regla 11: <Cuerpo> -> <listDecl> <listaS>
   SEL = { a f i } [ u t q s z p b } */
static void Cuerpo(void)
{
    listDecl();
    listaS();
}

/* Reglas 12 y 13: <listDecl> -> ξ | <Decl> <listDecl> */
static void listDecl(void)
{
    switch (c) {
    case 'f': case 'i':                     /* regla 13, SEL = { f i } */
        Decl();
        listDecl();
        break;
    case 'a': case '}': case '[': case 'u': case 't':
    case 'q': case 's': case 'z': case 'p': case 'b':
                                            /* regla 12, SEL = { a } [ u t q s z p b } */
        break;
    default:
        error_sintactico("una declaracion, una sentencia o '}'");
        sincronizar_lista("fia}[utqszpb");  /* SEL(12) y SEL(13) */
        if (c != FIN_DE_ENTRADA)
            listDecl();
    }
}

/* Regla 14: <Decl> -> <Tipo> a <valorIni> <listaVar> ;     SEL = { f i } */
static void Decl(void)
{
    Tipo();
    consumir('a');
    valorIni();
    listaVar();
    consumir(';');
}

/* Reglas 15 y 16: <Tipo> -> f | i */
static void Tipo(void)
{
    switch (c) {
    case 'f':                               /* regla 15, SEL = { f } */
        consumir('f');
        break;
    case 'i':                               /* regla 16, SEL = { i } */
        consumir('i');
        break;
    default:
        error_sintactico("un tipo (flutuador o inteiro)");
        sincronizar("a");                   /* SIG(<Tipo>) */
    }
}

/* Reglas 17 y 18: <valorIni> -> = <tipoVal> | ξ */
static void valorIni(void)
{
    switch (c) {
    case '=':                               /* regla 17, SEL = { = } */
        consumir('=');
        tipoVal();
        break;
    case ',': case ';':                     /* regla 18, SEL = { , ; } */
    default:                                /* ξ por omisión (ver el inicio) */
        break;
    }
}

/* Reglas 19 y 20: <listaVar> -> , a <valorIni> <listaVar> | ξ */
static void listaVar(void)
{
    switch (c) {
    case ',':                               /* regla 19, SEL = { , } */
        consumir(',');
        consumir('a');
        valorIni();
        listaVar();
        break;
    case ';':                               /* regla 20, SEL = { ; } */
    default:                                /* ξ por omisión */
        break;
    }
}

/* Reglas 21 y 22: <tipoVal> -> n | v */
static void tipoVal(void)
{
    switch (c) {
    case 'n':                               /* regla 21, SEL = { n } */
        consumir('n');
        break;
    case 'v':                               /* regla 22, SEL = { v } */
        consumir('v');
        break;
    default:
        error_sintactico("una constante entera o una constante cadena");
        sincronizar(",;");                  /* SIG(<tipoVal>) */
    }
}


/* =============================================================================
 *  BLOQUE 2: expresiones (reglas 23 a 49, 61 a 68, 77 a 81 y 87 a 92)
 * ========================================================================== */

/* Regla 23: <Asig> -> a <opArit> E ;                        SEL = { a } */
static void Asig(void)
{
    consumir('a');
    opArit();
    E();
    consumir(';');
}

/* Reglas 24 a 29: <opArit> -> = | x | y | k | r | o
   (los átomos de =, +=, -=, *=, /= y %=) */
static void opArit(void)
{
    switch (c) {
    case '=':                               /* regla 24, SEL = { = } */
    case 'x':                               /* regla 25, SEL = { x } */
    case 'y':                               /* regla 26, SEL = { y } */
    case 'k':                               /* regla 27, SEL = { k } */
    case 'r':                               /* regla 28, SEL = { r } */
    case 'o':                               /* regla 29, SEL = { o } */
        consumir(c);
        break;
    default:
        error_sintactico("un operador de asignacion (=, +=, -=, *=, /= o %=)");
        sincronizar("an([");                /* SIG(<opArit>) */
    }
}

/* Regla 30: E -> T E'                                 SEL = { a n ( [ } */
static void E(void)
{
    T();
    Ep();
}

/* Reglas 31 a 33: E' -> + T E' | - T E' | ξ */
static void Ep(void)
{
    switch (c) {
    case '+':                               /* regla 31, SEL = { + } */
        consumir('+');
        T();
        Ep();
        break;
    case '-':                               /* regla 32, SEL = { - } */
        consumir('-');
        T();
        Ep();
        break;
    case ')': case '}': case ',': case ';':
    case '>': case '<': case 'e': case 'd': case 'm': case 'w':
    case 'h': case 'j':                     /* regla 33, SEL = { ) } , ; > < e d m w h j } */
    default:                                /* ξ por omisión */
        break;
    }
}

/* Regla 34: T -> F T'                                 SEL = { a n ( [ } */
static void T(void)
{
    F();
    Tp();
}

/* Reglas 35 a 38: T' -> * F T' | / F T' | % F T' | ξ */
static void Tp(void)
{
    switch (c) {
    case '*':                               /* regla 35, SEL = { * } */
        consumir('*');
        F();
        Tp();
        break;
    case '/':                               /* regla 36, SEL = { / } */
        consumir('/');
        F();
        Tp();
        break;
    case '%':                               /* regla 37, SEL = { % } */
        consumir('%');
        F();
        Tp();
        break;
    case ')': case '}': case ',': case ';': case '+': case '-':
    case '>': case '<': case 'e': case 'd': case 'm': case 'w':
    case 'h': case 'j':                     /* regla 38, SEL = { ) } , ; + - > < e d m w h j } */
    default:                                /* ξ por omisión */
        break;
    }
}

/* Reglas 39 a 42: F -> ( E ) | a | n | <Llama> */
static void F(void)
{
    switch (c) {
    case '(':                               /* regla 39, SEL = { ( } */
        consumir('(');
        E();
        consumir(')');
        break;
    case 'a':                               /* regla 40, SEL = { a } */
        consumir('a');
        break;
    case 'n':                               /* regla 41, SEL = { n } */
        consumir('n');
        break;
    case '[':                               /* regla 42, SEL = { [ } */
        Llama();
        break;
    default:
        error_sintactico("un identificador, una constante entera, '(' o una llamada a funcion");
        sincronizar(")},;+-*/%><edmwhj");   /* SIG(F) */
    }
}

/* Regla 43: R -> E <opRel> E                          SEL = { a n ( [ } */
static void R(void)
{
    E();
    opRel();
    E();
}

/* Reglas 44 a 49: <opRel> -> > | < | e | d | m | w
   (los átomos de >, <, ==, !=, >= y <=) */
static void opRel(void)
{
    switch (c) {
    case '>':                               /* regla 44, SEL = { > } */
    case '<':                               /* regla 45, SEL = { < } */
    case 'e':                               /* regla 46, SEL = { e } */
    case 'd':                               /* regla 47, SEL = { d } */
    case 'm':                               /* regla 48, SEL = { m } */
    case 'w':                               /* regla 49, SEL = { w } */
        consumir(c);
        break;
    default:
        error_sintactico("un operador relacional (==, !=, >, <, >= o <=)");
        sincronizar("an([");                /* SIG(<opRel>) */
    }
}

/* Reglas 61 y 62: <expLogica> -> ! <expRel> | R <expLog> */
static void expLogica(void)
{
    switch (c) {
    case '!':                               /* regla 61, SEL = { ! } */
        consumir('!');
        expRel();
        break;
    case 'a': case 'n': case '(': case '[': /* regla 62, SEL = { a n ( [ } */
        R();
        expLog();
        break;
    default:
        error_sintactico("una condicion");
        sincronizar(")");                   /* SIG(<expLogica>) */
    }
}

/* Reglas 63 y 64: <expLog> -> <opLog> R | ξ */
static void expLog(void)
{
    switch (c) {
    case 'h': case 'j':                     /* regla 63, SEL = { h j } */
        opLog();
        R();
        break;
    case ')':                               /* regla 64, SEL = { ) } */
    default:                                /* ξ por omisión */
        break;
    }
}

/* Reglas 65 y 66: <expRel> -> { R } | E */
static void expRel(void)
{
    switch (c) {
    case '{':                               /* regla 65, SEL = { { } */
        consumir('{');
        R();
        consumir('}');
        break;
    case 'a': case 'n': case '(': case '[': /* regla 66, SEL = { a n ( [ } */
        E();
        break;
    default:
        error_sintactico("'{' o una expresion");
        sincronizar(")");                   /* SIG(<expRel>) */
    }
}

/* Reglas 67 y 68: <opLog> -> h | j   (los átomos de && y ||) */
static void opLog(void)
{
    switch (c) {
    case 'h':                               /* regla 67, SEL = { h } */
        consumir('h');
        break;
    case 'j':                               /* regla 68, SEL = { j } */
        consumir('j');
        break;
    default:
        error_sintactico("'&&' o '||'");
        sincronizar("an([");                /* SIG(<opLog>) */
    }
}

/* Reglas 77 y 78: <expCad> -> a <opCad> | v <opCad> */
static void expCad(void)
{
    switch (c) {
    case 'a':                               /* regla 77, SEL = { a } */
        consumir('a');
        opCad();
        break;
    case 'v':                               /* regla 78, SEL = { v } */
        consumir('v');
        opCad();
        break;
    default:
        error_sintactico("un identificador o una constante cadena");
        sincronizar("}");                   /* SIG(<expCad>) */
    }
}

/* Reglas 79 a 81: <opCad> -> l <expCad> | & <expCad> | ξ
   (la regla 80 usa & en lugar de h; ver el comentario al inicio) */
static void opCad(void)
{
    switch (c) {
    case 'l':                               /* regla 79, SEL = { l } */
        consumir('l');
        expCad();
        break;
    case '&':                               /* regla 80, SEL = { & } */
        consumir('&');
        expCad();
        break;
    case '}':                               /* regla 81, SEL = { } } */
    default:                                /* ξ por omisión */
        break;
    }
}

/* Regla 87: <Llama> -> [ a ( <listP> ) ]                    SEL = { [ } */
static void Llama(void)
{
    consumir('[');
    consumir('a');
    consumir('(');
    listP();
    consumir(')');
    consumir(']');
}

/* Reglas 88 a 90: <listP> -> ξ | E <Param> | { <expCad> } <Param> */
static void listP(void)
{
    switch (c) {
    case 'a': case 'n': case '(': case '[': /* regla 89, SEL = { a n ( [ } */
        E();
        Param();
        break;
    case '{':                               /* regla 90, SEL = { { } */
        consumir('{');
        expCad();
        consumir('}');
        Param();
        break;
    case ')':                               /* regla 88, SEL = { ) } */
    default:                                /* ξ por omisión */
        break;
    }
}

/* Reglas 91 y 92: <Param> -> , <listP> | ξ */
static void Param(void)
{
    switch (c) {
    case ',':                               /* regla 91, SEL = { , } */
        consumir(',');
        listP();
        break;
    case ')':                               /* regla 92, SEL = { ) } */
    default:                                /* ξ por omisión */
        break;
    }
}


/* =============================================================================
 *  BLOQUE 3: sentencias (reglas 50 a 60, 69 a 76 y 82 a 86)
 * ========================================================================== */

/* Reglas 50 a 58: <Sent> -> <Asig> | Q | <Ret> | <Trocar> | <Enq> | <Faz>
                            | <Se> | <Para> | <Llama> */
static void Sent(void)
{
    switch (c) {
    case 'a':                               /* regla 50, SEL = { a } */
        Asig();
        break;
    case 'u':                               /* regla 51, SEL = { u } */
        Q();
        break;
    case 't':                               /* regla 52, SEL = { t } */
        Ret();
        break;
    case 'b':                               /* regla 53, SEL = { b } */
        Trocar();
        break;
    case 'q':                               /* regla 54, SEL = { q } */
        Enq();
        break;
    case 'z':                               /* regla 55, SEL = { z } */
        Faz();
        break;
    case 's':                               /* regla 56, SEL = { s } */
        Se();
        break;
    case 'p':                               /* regla 57, SEL = { p } */
        Para();
        break;
    case '[':                               /* regla 58, SEL = { [ } */
        Llama();
        break;
    default:
        error_sintactico("una sentencia");
        sincronizar("a}[#utqszpb");         /* SIG(<Sent>) */
    }
}

/* Reglas 59 y 60: <listaS> -> <Sent> <listaS> | ξ */
static void listaS(void)
{
    switch (c) {
    case 'a': case '[': case 'u': case 't': case 'q':
    case 's': case 'z': case 'p': case 'b': /* regla 59, SEL = { a [ u t q s z p b } */
        Sent();
        listaS();
        break;
    case '}': case '#':                     /* regla 60, SEL = { } # } */
        break;
    case 'f': case 'i':
        /* Una declaración después de las sentencias. Se informa y se analiza
           como declaración, para seguir con lo que viene después de ella. */
        error_sintactico("una sentencia (las declaraciones van al inicio del cuerpo)");
        Decl();
        listaS();
        break;
    default:
        error_sintactico("una sentencia, '}' o '#'");
        sincronizar_lista("a[utqszpb}#");   /* SEL(59) y SEL(60) */
        if (c != FIN_DE_ENTRADA)
            listaS();
    }
}

/* Regla 69: <Enq> -> q ( <expLogica> ) # <listaS> #          SEL = { q } */
static void Enq(void)
{
    consumir('q');
    consumir('(');
    expLogica();
    consumir(')');
    consumir('#');
    listaS();
    consumir('#');
}

/* Regla 70: <Se> -> s ( <expLogica> ) # <listaS> #           SEL = { s } */
static void Se(void)
{
    consumir('s');
    consumir('(');
    expLogica();
    consumir(')');
    consumir('#');
    listaS();
    consumir('#');
}

/* Regla 71: Q -> u ;                                         SEL = { u } */
static void Q(void)
{
    consumir('u');
    consumir(';');
}

/* Regla 72: <Faz> -> z # <listaS> # q ( <expLogica> ) ;      SEL = { z } */
static void Faz(void)
{
    consumir('z');
    consumir('#');
    listaS();
    consumir('#');
    consumir('q');
    consumir('(');
    expLogica();
    consumir(')');
    consumir(';');
}

/* Regla 73: <Ret> -> t <valRet> ;                            SEL = { t } */
static void Ret(void)
{
    consumir('t');
    valRet();
    consumir(';');
}

/* Reglas 74 a 76: <valRet> -> E | { <expCad> } | ξ */
static void valRet(void)
{
    switch (c) {
    case 'a': case 'n': case '(': case '[': /* regla 74, SEL = { a n ( [ } */
        E();
        break;
    case '{':                               /* regla 75, SEL = { { } */
        consumir('{');
        expCad();
        consumir('}');
        break;
    case ';':                               /* regla 76, SEL = { ; } */
    default:                                /* ξ por omisión */
        break;
    }
}

/* Regla 82: <Para> -> p a [ n , n ] # <listaS> #             SEL = { p } */
static void Para(void)
{
    consumir('p');
    consumir('a');
    consumir('[');
    consumir('n');
    consumir(',');
    consumir('n');
    consumir(']');
    consumir('#');
    listaS();
    consumir('#');
}

/* Regla 83: <Trocar> -> b ( a ) : # c ( n ) { <listaS> } <casos> #
                                                              SEL = { b } */
static void Trocar(void)
{
    consumir('b');
    consumir('(');
    consumir('a');
    consumir(')');
    consumir(':');
    consumir('#');
    consumir('c');
    consumir('(');
    consumir('n');
    consumir(')');
    consumir('{');
    listaS();
    consumir('}');
    casos();
    consumir('#');
}

/* Reglas 84 a 86: <casos> -> ξ | c ( n ) { <listaS> } <casos>
                            | ( ) { <listaS> } <casos> */
static void casos(void)
{
    switch (c) {
    case '#':                               /* regla 84, SEL = { # } */
        break;
    case 'c':                               /* regla 85, SEL = { c } */
        consumir('c');
        consumir('(');
        consumir('n');
        consumir(')');
        consumir('{');
        listaS();
        consumir('}');
        casos();
        break;
    case '(':                               /* regla 86, SEL = { ( } */
        consumir('(');
        consumir(')');
        consumir('{');
        listaS();
        consumir('}');
        casos();
        break;
    default:
        error_sintactico("'caso', '()' o '#'");
        sincronizar_lista("c#");            /* el siguiente caso o el fin del trocar */
        if (c != FIN_DE_ENTRADA)
            casos();
    }
}


/* =============================================================================
 *  Funciones de apoyo
 * ========================================================================== */

/* -----------------------------------------------------------------------------
 *  avanzar: pasa al siguiente átomo. Nunca rebasa el último, que es el $.
 * -------------------------------------------------------------------------- */
static void avanzar(void)
{
    if (pos < total - 1)
        pos++;
    c = atomos[pos].simbolo;
}

/* -----------------------------------------------------------------------------
 *  consumir: si el átomo actual es el esperado, avanza al siguiente y termina
 *  la recuperación de un error anterior. Si no, informa el error. Cuando el
 *  átomo que sigue sí es el esperado, el actual sobra: se salta y se consume
 *  el esperado. En cualquier otro caso no avanza, como si el esperado
 *  faltara.
 * -------------------------------------------------------------------------- */
static void consumir(char esperado)
{
    if (c == esperado) {
        avanzar();
        en_recuperacion = 0;
    } else if (c != FIN_DE_ENTRADA && pos + 1 < total
               && atomos[pos + 1].simbolo == esperado) {
        informar_error(nombre_terminal(esperado), 1);
        avanzar();                          /* salta el átomo que sobra */
        avanzar();                          /* consume el esperado      */
        en_recuperacion = 0;
    } else {
        informar_error(nombre_terminal(esperado), 1);
    }
}

/* -----------------------------------------------------------------------------
 *  sincronizar: salta átomos hasta encontrar uno del conjunto indicado (el
 *  SIGUIENTE del no terminal), un delimitador o el fin de la entrada. El
 *  conjunto se escribe como una cadena de átomos.
 * -------------------------------------------------------------------------- */
static void sincronizar(const char *conjunto)
{
    while (c != FIN_DE_ENTRADA && strchr(conjunto, c) == NULL
           && strchr(DELIMITADORES, c) == NULL)
        avanzar();
}

/* -----------------------------------------------------------------------------
 *  sincronizar_lista: como sincronizar, pero se detiene solo en los átomos
 *  del conjunto (los de los conjuntos selección de la lista) o en el fin de
 *  la entrada. Así, al volver a llamar a la función de la lista, el átomo
 *  actual siempre se consume o lleva a la regla ξ, y no hay ciclos infinitos.
 * -------------------------------------------------------------------------- */
static void sincronizar_lista(const char *conjunto)
{
    while (c != FIN_DE_ENTRADA && strchr(conjunto, c) == NULL)
        avanzar();
}

/* -----------------------------------------------------------------------------
 *  error_sintactico: informa que el átomo actual no está en ningún conjunto
 *  selección de las reglas del no terminal. "esperado" describe lo que podía
 *  ir en ese lugar.
 * -------------------------------------------------------------------------- */
static void error_sintactico(const char *esperado)
{
    informar_error(esperado, 0);
}

/* -----------------------------------------------------------------------------
 *  informar_error: cuenta el error y lo escribe con la línea y la columna del
 *  átomo actual, lo que se esperaba y lo que se encontró. Cuando falta un
 *  terminal (con_anterior = 1) y el átomo anterior está en otra línea,
 *  también lo menciona: un ';' que falta al final de una línea se detecta
 *  hasta el primer átomo de la línea siguiente. Mientras dura la
 *  recuperación de un error anterior no informa nada.
 * -------------------------------------------------------------------------- */
static void informar_error(const char *esperado, int con_anterior)
{
    const Atomo *actual = &atomos[pos];
    char         encontrado[48];
    char         anterior[48];

    if (en_recuperacion)
        return;
    en_recuperacion = 1;
    errores++;

    escribir_lexema(actual, encontrado, sizeof(encontrado));

    if (con_anterior && pos > 0 && atomos[pos - 1].linea != actual->linea) {
        escribir_lexema(&atomos[pos - 1], anterior, sizeof(anterior));
        reportar("Error sintactico en linea %d, columna %d: se esperaba %s "
                 "despues de %s (linea %d); se encontro %s.\n",
                 actual->linea, actual->columna, esperado,
                 anterior, atomos[pos - 1].linea, encontrado);
    } else {
        reportar("Error sintactico en linea %d, columna %d: se esperaba %s; "
                 "se encontro %s.\n",
                 actual->linea, actual->columna, esperado, encontrado);
    }
}

/* -----------------------------------------------------------------------------
 *  escribir_lexema: deja en destino el lexema del átomo entre comillas
 *  simples, con los saltos de línea visibles como \n y recortado si es muy
 *  largo (una cadena puede ocupar varias líneas). Para el $ escribe
 *  "el fin del archivo".
 * -------------------------------------------------------------------------- */
static void escribir_lexema(const Atomo *atomo, char *destino, size_t tam)
{
    const char *p = atomo->lexema;
    size_t      n = 0;

    if (atomo->simbolo == FIN_DE_ENTRADA) {
        strncpy(destino, "el fin del archivo", tam - 1);
        destino[tam - 1] = '\0';
        return;
    }

    destino[n++] = '\'';
    for (; *p != '\0' && n < tam - 6; p++) {
        if (*p == '\n') {
            destino[n++] = '\\';
            destino[n++] = 'n';
        } else if (*p != '\r') {
            destino[n++] = *p;
        }
    }
    if (*p != '\0') {
        destino[n++] = '.';
        destino[n++] = '.';
        destino[n++] = '.';
    }
    destino[n++] = '\'';
    destino[n]   = '\0';
}

/* -----------------------------------------------------------------------------
 *  nombre_terminal: describe un átomo con las palabras del programa fuente,
 *  para que el mensaje de error se entienda sin conocer la tabla de átomos.
 * -------------------------------------------------------------------------- */
static const char *nombre_terminal(char t)
{
    static char simbolo[4];

    switch (t) {
    case 'a': return "un identificador";
    case 'n': return "una constante entera";
    case 'v': return "una constante cadena";
    case 'g': return "'assinado'";
    case 'c': return "'caso'";
    case 'q': return "'enquanto'";
    case 'z': return "'fazer'";
    case 'f': return "'flutuador'";
    case 'i': return "'inteiro'";
    case 'p': return "'para'";
    case 'u': return "'quebrar'";
    case 't': return "'retorno'";
    case 's': return "'se'";
    case 'b': return "'trocar'";
    case 'e': return "'=='";
    case 'd': return "'!='";
    case 'm': return "'>='";
    case 'w': return "'<='";
    case 'h': return "'&&'";
    case 'j': return "'||'";
    case 'x': return "'+='";
    case 'y': return "'-='";
    case 'k': return "'*='";
    case 'r': return "'/='";
    case 'o': return "'%='";
    case 'l': return "'like'";
    case FIN_DE_ENTRADA: return "el fin del archivo";
    default:
        /* Símbolos que se escriben igual que su átomo: ( ) { } [ ] , ; : #
           + - * / % > < ! = & */
        simbolo[0] = '\'';
        simbolo[1] = t;
        simbolo[2] = '\'';
        simbolo[3] = '\0';
        return simbolo;
    }
}

/* -----------------------------------------------------------------------------
 *  reportar: escribe el mensaje en pantalla y, si existe, en la bitácora.
 * -------------------------------------------------------------------------- */
static void reportar(const char *formato, ...)
{
    va_list argumentos;

    va_start(argumentos, formato);
    vprintf(formato, argumentos);
    va_end(argumentos);

    if (bitacora != NULL) {
        va_start(argumentos, formato);
        vfprintf(bitacora, formato, argumentos);
        va_end(argumentos);
    }
}
