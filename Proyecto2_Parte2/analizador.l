%{
/* =============================================================================
 *  PROYECTO 2, PARTE 2  -  ANALIZADOR LÉXICO (FLEX) + ANALIZADOR SINTÁCTICO
 *
 *  Materia:  Compiladores
 *  Equipo:   Baños Monjaraz José Guadalupe
 *            Castañeda Carrasco Luisa Valentina
 *            Solis Espinosa Pedro Alberto
 *  Fecha de elaboración: 16 de noviembre de 2026
 *
 *  Qué hace el programa:
 *    Lee un programa fuente desde el archivo indicado en la línea de comandos
 *    y reconoce los componentes léxicos de las 10 clases definidas en el
 *    proyecto 1. Por cada componente genera un token (clase, valor) y el
 *    átomo que le corresponde según la tabla del Anexo A, con la línea y la
 *    columna donde empieza. Guarda los identificadores en la tabla de
 *    símbolos y las constantes cadena en la tabla de literales. Cada error
 *    léxico se informa en pantalla y en errores.txt, y el análisis continúa.
 *    Al terminar muestra los tokens, las dos tablas y la secuencia de átomos.
 *    Si no hubo errores léxicos, entrega los átomos al analizador sintáctico
 *    descendente recursivo (parser.c); si los hubo, no lo ejecuta.
 *    Los resultados se guardan en tokens.txt, tabla_simbolos.txt,
 *    tabla_literales.txt, atomos.txt y errores.txt.
 *
 *  Compilación:   flex analizador.l
 *                 gcc lex.yy.c parser.c -o analizador
 *
 *  Ejecución:     ./analizador programa.txt      (Linux / macOS)
 *                 analizador.exe programa.txt    (Windows)
 * ============================================================================= */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include "parser.h"

/* -----------------------------------------------------------------------------
 *  Clases de componentes léxicos (campo "clase" del token)
 * -------------------------------------------------------------------------- */
#define CLASE_OP_ARITMETICO   0
#define CLASE_OP_LOGICO       1
#define CLASE_OP_RELACIONAL   2
#define CLASE_CONST_ENTERA    3
#define CLASE_PAL_RESERVADA   4
#define CLASE_IDENTIFICADOR   5
#define CLASE_SIMB_ESPECIAL   6
#define CLASE_OP_ASIGNACION   7
#define CLASE_CONST_CADENA    8
#define CLASE_OP_CADENA       9

/* Número de cubetas de la tabla hash de identificadores (número primo). */
#define TAM_HASH            211

/* Capacidad con la que nacen los arreglos dinámicos; después se duplica. */
#define CAPACIDAD_INICIAL   16

/* Número de elementos de un arreglo declarado de forma estática. */
#define NUM_ELEMENTOS(arreglo)  ((int)(sizeof(arreglo) / sizeof((arreglo)[0])))

/* -----------------------------------------------------------------------------
 *  Catálogos: el valor del token es la posición del lexema en su catálogo.
 * -------------------------------------------------------------------------- */
static const char *PALABRAS_RESERVADAS[] = {
    "assinado", "caso", "enquanto", "fazer", "flutuador", "inteiro",
    "para", "quebrar", "retorno", "se", "trocar"
};
static const char *OPERADORES_LOGICOS[]     = { "&&", "||", "!" };
static const char *OPERADORES_RELACIONALES[] = { "==", "!=", ">", "<", ">=", "<=" };
static const char *OPERADORES_ASIGNACION[]  = { "=", "+=", "-=", "*=", "/=", "%=" };
static const char *OPERADORES_CADENA[]      = { "&", "like" };

/* -----------------------------------------------------------------------------
 *  Átomos (tabla del Anexo A). En las clases con catálogo, el átomo del token
 *  con valor v es el carácter v de la cadena correspondiente. Por ejemplo, el
 *  valor 4 de las palabras reservadas (flutuador) tiene el átomo
 *  ATOMOS_RESERVADAS[4], que es 'f'. Las demás clases se resuelven en
 *  atomo_de_token().
 * -------------------------------------------------------------------------- */
static const char ATOMOS_RESERVADAS[]   = "gcqzfiputsb"; /* assinado ... trocar  */
static const char ATOMOS_LOGICOS[]      = "hj!";         /* &&  ||  !            */
static const char ATOMOS_RELACIONALES[] = "ed><mw";      /* == != > < >= <=      */
static const char ATOMOS_ASIGNACION[]   = "=xykro";      /* = += -= *= /= %=     */
static const char ATOMOS_CADENA[]       = "&l";          /* &  like              */

/* -----------------------------------------------------------------------------
 *  Token: estructura de dos campos, clase y valor.
 *  Los tokens se guardan en un arreglo dinámico en el orden en que aparecen.
 * -------------------------------------------------------------------------- */
typedef struct {
    int clase;      /* clase del componente léxico (0 a 9)                  */
    int valor;      /* valor del token según su clase                        */
} Token;

typedef struct {
    Token *elementos;   /* arreglo dinámico de tokens                        */
    int    cantidad;    /* tokens guardados                                  */
    int    capacidad;   /* tokens que caben antes de ampliar el arreglo      */
} ListaTokens;

/* -----------------------------------------------------------------------------
 *  Lista de átomos: se llena al mismo tiempo que la de tokens y en el mismo
 *  orden. Cada átomo guarda además su línea, su columna y su lexema (la
 *  estructura Atomo está en parser.h). Al final se agrega el átomo $.
 * -------------------------------------------------------------------------- */
typedef struct {
    Atomo *elementos;   /* arreglo dinámico de átomos                        */
    int    cantidad;    /* átomos guardados                                  */
    int    capacidad;   /* átomos que caben antes de ampliar el arreglo      */
} ListaAtomos;

/* -----------------------------------------------------------------------------
 *  Tabla de símbolos: arreglo dinámico de registros (en orden de inserción)
 *  más una tabla hash con encadenamiento para buscar por nombre.
 *  cubetas[h] guarda la posición del primer registro cuyo nombre cae en la
 *  cubeta h, y cada registro guarda en "siguiente" la posición del próximo
 *  registro de la misma cubeta (-1 indica el final de la cadena).
 * -------------------------------------------------------------------------- */
typedef struct {
    int   posicion;     /* posición en la tabla: 0, 1, 2, ...                */
    char *nombre;       /* nombre del identificador                          */
    int   tipo;         /* tipo del identificador; -1 mientras no se conozca */
    int   siguiente;    /* siguiente registro de la misma cubeta, o -1       */
} Simbolo;

typedef struct {
    Simbolo *registros;           /* registros en orden de inserción         */
    int      cantidad;            /* identificadores guardados               */
    int      capacidad;           /* registros que caben antes de ampliar    */
    int      cubetas[TAM_HASH];   /* inicio de cada cadena, o -1 si vacía    */
} TablaSimbolos;

/* -----------------------------------------------------------------------------
 *  Tabla de literales: arreglo dinámico de registros (posición, dato).
 *  Cada cadena se inserta al final sin revisar si ya existe.
 * -------------------------------------------------------------------------- */
typedef struct {
    int   posicion;     /* posición en la tabla: 0, 1, 2, ...                */
    char *dato;         /* la cadena tal como aparece, con sus comillas      */
} Literal;

typedef struct {
    Literal *registros;   /* registros en orden de inserción                 */
    int      cantidad;    /* cadenas guardadas                               */
    int      capacidad;   /* registros que caben antes de ampliar            */
} TablaLiterales;

/* -----------------------------------------------------------------------------
 *  Variables globales del analizador
 * -------------------------------------------------------------------------- */
static ListaTokens    lista_tokens;
static ListaAtomos    lista_atomos;
static TablaSimbolos  tabla_simbolos;
static TablaLiterales tabla_literales;
static FILE          *archivo_errores = NULL;  /* errores.txt                    */
static int            total_errores   = 0;     /* errores léxicos hallados       */
static int            linea_actual    = 1;     /* línea del siguiente carácter   */
static int            columna_actual  = 1;     /* columna del siguiente carácter */
static int            linea_token     = 1;     /* línea donde empieza el
                                                  componente que se reconoció   */
static int            columna_token   = 1;     /* columna donde empieza          */

/* -----------------------------------------------------------------------------
 *  Prototipos (las funciones se definen en la tercera sección del archivo)
 * -------------------------------------------------------------------------- */
static void *ampliar_arreglo(void *arreglo, int *capacidad, size_t tam_elemento);
static char *copiar_texto(const char *texto);
static void  inicializar_tablas(void);
static void  saltar_bom(FILE *archivo);
static void  agregar_token(int clase, int valor);
static int   buscar_en_catalogo(const char *catalogo[], int cantidad, const char *lexema);
static unsigned int funcion_hash(const char *nombre);
static int   buscar_simbolo(const char *nombre);
static int   insertar_simbolo(const char *nombre);
static int   insertar_literal(const char *cadena);
static int   convertir_constante(const char *lexema, int *valor);
static void  marcar_posicion(const char *texto);
static char  atomo_de_token(int clase, int valor);
static void  agregar_atomo(char simbolo, const char *lexema, int linea, int columna);
static void  escribir_visible(FILE *salida, const char *texto);
static void  reportar_error(const char *descripcion, const char *lexema);
static const char *nombre_clase(int clase);
static void  escribir_lexema(FILE *salida, Token token);
static void  mostrar_tokens(FILE *salida);
static void  mostrar_tabla_simbolos(FILE *salida);
static void  mostrar_tabla_literales(FILE *salida);
static void  mostrar_atomos(FILE *salida);
static void  guardar_resultados(void);
static void  liberar_memoria(void);

/* Flex ejecuta YY_USER_ACTION justo antes de la acción de cada regla. Ahí se
   guarda la posición donde empieza el componente reconocido y se avanzan la
   línea y la columna con el texto que ocupa (delimitadores incluidos). */
#define YY_USER_ACTION  marcar_posicion(yytext);
%}

%option noyywrap
%option nounput
%option noinput
%option 8bit

/* =============================================================================
 *  Definiciones regulares (equivalentes a las expresiones de la parte 1)
 * ========================================================================== */

/* Definiciones auxiliares */
DIGITO          [0-9]
LETRA           [a-zA-Z]
SIGNO           [+-]

/* Clase 0: operadores aritméticos */
OP_ARITMETICO   [-+*/%]

/* Clase 1: operadores lógicos */
OP_LOGICO       "&&"|"||"|"!"

/* Clase 2: operadores relacionales */
OP_RELACIONAL   "=="|"!="|">"|"<"|">="|"<="

/* Clase 3: constantes enteras en base 10; con signo van entre paréntesis */
CONST_ENTERA    {DIGITO}+|"("{SIGNO}{DIGITO}+")"

/* Clase 4: palabras reservadas */
PAL_RESERVADA   assinado|caso|enquanto|fazer|flutuador|inteiro|para|quebrar|retorno|se|trocar

/* Clase 5: identificadores; inician con _ seguido de una letra */
IDENTIFICADOR   _{LETRA}({LETRA}|{DIGITO}|_)*

/* Clase 6: símbolos especiales */
SIMB_ESPECIAL   [(){};,\[\]:#]

/* Clase 7: operadores de asignación */
OP_ASIGNACION   "="|"+="|"-="|"*="|"/="|"%="

/* Clase 8: constantes cadena; cualquier carácter salvo la comilla, incluido el salto de línea */
CONST_CADENA    \"[^"]*\"

/* Clase 9: operadores sobre cadenas */
OP_CADENA       "&"|like

/* Delimitadores: espacio, tabulador y salto de línea (\r por los archivos de Windows) */
DELIMITADOR     [ \t\r\n]+

%%

{DELIMITADOR}       {
                        /* Los delimitadores solo separan componentes: no
                           generan token ni átomo. Las líneas y columnas que
                           ocupan ya se contaron en YY_USER_ACTION. */
                    }

{CONST_CADENA}      {
                        /* Clase 8. La cadena se inserta al final de la tabla
                           de literales y el valor es su posición. */
                        agregar_token(CLASE_CONST_CADENA, insertar_literal(yytext));
                    }

\"                  {
                        /* Una comilla sin su comilla de cierre. Como la regla
                           anterior siempre es más larga cuando la cadena sí
                           cierra, esta regla solo aplica a cadenas sin cerrar.
                           Se informa el error y se sigue con el carácter
                           siguiente a la comilla. */
                        reportar_error("cadena sin cerrar (falta la comilla final)", yytext);
                    }

{PAL_RESERVADA}     {
                        /* Clase 4. Va antes de [a-z]+ para ganar el empate
                           cuando ambas reglas reconocen la misma longitud. */
                        agregar_token(CLASE_PAL_RESERVADA,
                                      buscar_en_catalogo(PALABRAS_RESERVADAS,
                                                         NUM_ELEMENTOS(PALABRAS_RESERVADAS),
                                                         yytext));
                    }

{OP_CADENA}         {
                        /* Clase 9: & y like. "like" también va antes de
                           [a-z]+ por la misma razón. "&&" es más largo que
                           "&", así que la regla de operadores lógicos gana. */
                        agregar_token(CLASE_OP_CADENA,
                                      buscar_en_catalogo(OPERADORES_CADENA,
                                                         NUM_ELEMENTOS(OPERADORES_CADENA),
                                                         yytext));
                    }

[a-z]+              {
                        /* Una palabra en minúsculas que no es reservada ni
                           "like". Como es más larga que cualquier prefijo
                           reservado, evita que "sea" se tome como "se" + "a". */
                        reportar_error("palabra no reservada (los identificadores inician con _)", yytext);
                    }

{IDENTIFICADOR}     {
                        /* Clase 5. Se busca el nombre en la tabla de símbolos;
                           si no está se inserta. El valor es su posición. */
                        agregar_token(CLASE_IDENTIFICADOR, insertar_simbolo(yytext));
                    }

{CONST_ENTERA}      {
                        /* Clase 3. El valor es el número; el signo + se omite.
                           "(" sola es más corta, así que esta regla gana
                           cuando la constante con signo está completa. */
                        int numero;
                        if (convertir_constante(yytext, &numero))
                            agregar_token(CLASE_CONST_ENTERA, numero);
                        else
                            reportar_error("constante fuera del rango de inteiro", yytext);
                    }

{OP_ASIGNACION}     {
                        /* Clase 7. "==" es más largo que "=", así que la regla
                           de operadores relacionales gana en ese caso. */
                        agregar_token(CLASE_OP_ASIGNACION,
                                      buscar_en_catalogo(OPERADORES_ASIGNACION,
                                                         NUM_ELEMENTOS(OPERADORES_ASIGNACION),
                                                         yytext));
                    }

{OP_RELACIONAL}     {
                        /* Clase 2 */
                        agregar_token(CLASE_OP_RELACIONAL,
                                      buscar_en_catalogo(OPERADORES_RELACIONALES,
                                                         NUM_ELEMENTOS(OPERADORES_RELACIONALES),
                                                         yytext));
                    }

{OP_LOGICO}         {
                        /* Clase 1 */
                        agregar_token(CLASE_OP_LOGICO,
                                      buscar_en_catalogo(OPERADORES_LOGICOS,
                                                         NUM_ELEMENTOS(OPERADORES_LOGICOS),
                                                         yytext));
                    }

{OP_ARITMETICO}     {
                        /* Clase 0. El valor es el código ASCII del carácter.
                           "+=", "-=", etc. son más largos y se reconocen
                           como asignación. */
                        agregar_token(CLASE_OP_ARITMETICO, (unsigned char) yytext[0]);
                    }

{SIMB_ESPECIAL}     {
                        /* Clase 6. El valor es el código ASCII del carácter. */
                        agregar_token(CLASE_SIMB_ESPECIAL, (unsigned char) yytext[0]);
                    }

[\xC0-\xFF][\x80-\xBF]* {
                        /* Un carácter acentuado o especial codificado en
                           UTF-8 (por ejemplo ñ o á) ocupa varios bytes; se
                           informa como un solo carácter no válido. */
                        reportar_error("caracter no valido", yytext);
                    }

.                   {
                        /* Cualquier otro carácter (mayúscula inicial, $, @,
                           un | solo, un _ sin letra después, etc.). Se informa
                           y el análisis sigue con el carácter siguiente. */
                        reportar_error("caracter no valido", yytext);
                    }

%%

/* =============================================================================
 *  Funciones auxiliares
 * ========================================================================== */

/* -----------------------------------------------------------------------------
 *  ampliar_arreglo: duplica la capacidad de un arreglo dinámico con realloc.
 *  Recibe el arreglo, su capacidad actual (que se actualiza) y el tamaño de
 *  cada elemento. Devuelve el arreglo ampliado. Termina el programa si no hay
 *  memoria suficiente.
 * -------------------------------------------------------------------------- */
static void *ampliar_arreglo(void *arreglo, int *capacidad, size_t tam_elemento)
{
    int   nueva_capacidad = (*capacidad == 0) ? CAPACIDAD_INICIAL : *capacidad * 2;
    void *nuevo = realloc(arreglo, (size_t) nueva_capacidad * tam_elemento);

    if (nuevo == NULL) {
        fprintf(stderr, "Error: memoria insuficiente.\n");
        exit(EXIT_FAILURE);
    }
    *capacidad = nueva_capacidad;
    return nuevo;
}

/* -----------------------------------------------------------------------------
 *  copiar_texto: reserva memoria y devuelve una copia de la cadena recibida.
 *  Hace falta porque yytext cambia con cada componente reconocido.
 * -------------------------------------------------------------------------- */
static char *copiar_texto(const char *texto)
{
    size_t longitud = strlen(texto);
    char  *copia    = malloc(longitud + 1);

    if (copia == NULL) {
        fprintf(stderr, "Error: memoria insuficiente.\n");
        exit(EXIT_FAILURE);
    }
    memcpy(copia, texto, longitud + 1);
    return copia;
}

/* -----------------------------------------------------------------------------
 *  inicializar_tablas: deja vacías la lista de tokens y ambas tablas, y marca
 *  todas las cubetas de la tabla hash como vacías (-1).
 * -------------------------------------------------------------------------- */
static void inicializar_tablas(void)
{
    int i;

    memset(&lista_tokens, 0, sizeof(lista_tokens));
    memset(&lista_atomos, 0, sizeof(lista_atomos));
    memset(&tabla_simbolos, 0, sizeof(tabla_simbolos));
    memset(&tabla_literales, 0, sizeof(tabla_literales));
    for (i = 0; i < TAM_HASH; i++)
        tabla_simbolos.cubetas[i] = -1;
}

/* -----------------------------------------------------------------------------
 *  saltar_bom: algunos editores de Windows guardan al inicio del archivo una
 *  marca de 3 bytes (EF BB BF) que indica UTF-8. No forma parte del programa,
 *  así que si está se salta; si no está, se regresa al inicio del archivo.
 * -------------------------------------------------------------------------- */
static void saltar_bom(FILE *archivo)
{
    unsigned char marca[3];
    size_t        leidos = fread(marca, 1, 3, archivo);

    if (!(leidos == 3 && marca[0] == 0xEF && marca[1] == 0xBB && marca[2] == 0xBF))
        rewind(archivo);
}

/* -----------------------------------------------------------------------------
 *  agregar_token: guarda el token (clase, valor) al final de la lista y, al
 *  mismo tiempo, su átomo con el lexema y la posición donde empieza.
 * -------------------------------------------------------------------------- */
static void agregar_token(int clase, int valor)
{
    if (lista_tokens.cantidad == lista_tokens.capacidad)
        lista_tokens.elementos = ampliar_arreglo(lista_tokens.elementos,
                                                 &lista_tokens.capacidad,
                                                 sizeof(Token));

    lista_tokens.elementos[lista_tokens.cantidad].clase = clase;
    lista_tokens.elementos[lista_tokens.cantidad].valor = valor;
    lista_tokens.cantidad++;

    agregar_atomo(atomo_de_token(clase, valor), yytext, linea_token, columna_token);
}

/* -----------------------------------------------------------------------------
 *  atomo_de_token: devuelve el átomo que corresponde al token (clase, valor)
 *  según la tabla del Anexo A.
 * -------------------------------------------------------------------------- */
static char atomo_de_token(int clase, int valor)
{
    switch (clase) {
        case CLASE_OP_ARITMETICO:  return (char) valor;  /* + - * / % : el mismo símbolo */
        case CLASE_OP_LOGICO:      return ATOMOS_LOGICOS[valor];
        case CLASE_OP_RELACIONAL:  return ATOMOS_RELACIONALES[valor];
        case CLASE_CONST_ENTERA:   return 'n';
        case CLASE_PAL_RESERVADA:  return ATOMOS_RESERVADAS[valor];
        case CLASE_IDENTIFICADOR:  return 'a';
        case CLASE_SIMB_ESPECIAL:  return (char) valor;  /* ( ) { } ; , [ ] : # : el mismo símbolo */
        case CLASE_OP_ASIGNACION:  return ATOMOS_ASIGNACION[valor];
        case CLASE_CONST_CADENA:   return 'v';
        case CLASE_OP_CADENA:      return ATOMOS_CADENA[valor];
        default:                   return '?';
    }
}

/* -----------------------------------------------------------------------------
 *  agregar_atomo: guarda un átomo al final de la lista con una copia de su
 *  lexema y la línea y columna donde empieza.
 * -------------------------------------------------------------------------- */
static void agregar_atomo(char simbolo, const char *lexema, int linea, int columna)
{
    Atomo *nuevo;

    if (lista_atomos.cantidad == lista_atomos.capacidad)
        lista_atomos.elementos = ampliar_arreglo(lista_atomos.elementos,
                                                 &lista_atomos.capacidad,
                                                 sizeof(Atomo));

    nuevo = &lista_atomos.elementos[lista_atomos.cantidad];
    nuevo->simbolo = simbolo;
    nuevo->linea   = linea;
    nuevo->columna = columna;
    nuevo->lexema  = copiar_texto(lexema);
    lista_atomos.cantidad++;
}

/* -----------------------------------------------------------------------------
 *  buscar_en_catalogo: búsqueda secuencial del lexema en un catálogo fijo.
 *  Devuelve la posición donde está, o -1 si no está (no debería ocurrir,
 *  porque la expresión regular solo deja pasar lexemas del catálogo).
 * -------------------------------------------------------------------------- */
static int buscar_en_catalogo(const char *catalogo[], int cantidad, const char *lexema)
{
    int i;

    for (i = 0; i < cantidad; i++)
        if (strcmp(catalogo[i], lexema) == 0)
            return i;
    return -1;
}

/* -----------------------------------------------------------------------------
 *  funcion_hash: convierte el nombre de un identificador en un número de
 *  cubeta entre 0 y TAM_HASH - 1. Usa el método djb2: h = h * 33 + carácter,
 *  empezando con h = 5381, y al final toma el residuo entre TAM_HASH.
 * -------------------------------------------------------------------------- */
static unsigned int funcion_hash(const char *nombre)
{
    unsigned long h = 5381;

    while (*nombre != '\0') {
        h = h * 33 + (unsigned char) *nombre;
        nombre++;
    }
    return (unsigned int) (h % TAM_HASH);
}

/* -----------------------------------------------------------------------------
 *  buscar_simbolo: calcula la cubeta del nombre y recorre su cadena
 *  comparando nombres. Devuelve la posición del identificador en la tabla
 *  de símbolos, o -1 si no está.
 * -------------------------------------------------------------------------- */
static int buscar_simbolo(const char *nombre)
{
    int indice = tabla_simbolos.cubetas[funcion_hash(nombre)];

    while (indice != -1) {
        if (strcmp(tabla_simbolos.registros[indice].nombre, nombre) == 0)
            return indice;
        indice = tabla_simbolos.registros[indice].siguiente;
    }
    return -1;
}

/* -----------------------------------------------------------------------------
 *  insertar_simbolo: devuelve la posición del identificador en la tabla de
 *  símbolos. Primero lo busca; si ya existe devuelve su posición. Si no,
 *  lo agrega al final del arreglo con tipo -1 y lo enlaza al inicio de la
 *  cadena de su cubeta.
 * -------------------------------------------------------------------------- */
static int insertar_simbolo(const char *nombre)
{
    int          posicion = buscar_simbolo(nombre);
    unsigned int cubeta;
    Simbolo     *nuevo;

    if (posicion != -1)
        return posicion;

    if (tabla_simbolos.cantidad == tabla_simbolos.capacidad)
        tabla_simbolos.registros = ampliar_arreglo(tabla_simbolos.registros,
                                                   &tabla_simbolos.capacidad,
                                                   sizeof(Simbolo));

    posicion = tabla_simbolos.cantidad;
    cubeta   = funcion_hash(nombre);
    nuevo    = &tabla_simbolos.registros[posicion];

    nuevo->posicion  = posicion;
    nuevo->nombre    = copiar_texto(nombre);
    nuevo->tipo      = -1;
    nuevo->siguiente = tabla_simbolos.cubetas[cubeta];
    tabla_simbolos.cubetas[cubeta] = posicion;
    tabla_simbolos.cantidad++;

    return posicion;
}

/* -----------------------------------------------------------------------------
 *  insertar_literal: agrega la cadena al final de la tabla de literales, sin
 *  revisar si ya existe, y devuelve la posición donde quedó.
 * -------------------------------------------------------------------------- */
static int insertar_literal(const char *cadena)
{
    int posicion;

    if (tabla_literales.cantidad == tabla_literales.capacidad)
        tabla_literales.registros = ampliar_arreglo(tabla_literales.registros,
                                                    &tabla_literales.capacidad,
                                                    sizeof(Literal));

    posicion = tabla_literales.cantidad;
    tabla_literales.registros[posicion].posicion = posicion;
    tabla_literales.registros[posicion].dato     = copiar_texto(cadena);
    tabla_literales.cantidad++;

    return posicion;
}

/* -----------------------------------------------------------------------------
 *  convertir_constante: obtiene el valor numérico de una constante entera.
 *  Acepta "672" y también "(-265)" o "(+49)"; en esos casos salta el
 *  paréntesis inicial y strtol lee el signo y los dígitos hasta el ")".
 *  Devuelve 1 si el número cabe en un int (equivalente a inteiro) y lo deja
 *  en *valor; devuelve 0 si está fuera de rango.
 * -------------------------------------------------------------------------- */
static int convertir_constante(const char *lexema, int *valor)
{
    const char *inicio = (lexema[0] == '(') ? lexema + 1 : lexema;
    long        numero;

    errno  = 0;
    numero = strtol(inicio, NULL, 10);
    if (errno == ERANGE || numero > INT_MAX || numero < INT_MIN)
        return 0;

    *valor = (int) numero;
    return 1;
}

/* -----------------------------------------------------------------------------
 *  marcar_posicion: se llama desde YY_USER_ACTION con el texto que se acaba
 *  de reconocer. Guarda en linea_token y columna_token dónde empieza y
 *  después avanza linea_actual y columna_actual hasta el final del texto.
 *  Un salto de línea pasa a la columna 1 de la línea siguiente. Los bytes de
 *  continuación de UTF-8 (10xxxxxx) no cuentan como otra columna, para que
 *  una letra acentuada ocupe una sola. Un tabulador cuenta como una columna.
 * -------------------------------------------------------------------------- */
static void marcar_posicion(const char *texto)
{
    linea_token   = linea_actual;
    columna_token = columna_actual;

    for (; *texto != '\0'; texto++) {
        if (*texto == '\n') {
            linea_actual++;
            columna_actual = 1;
        } else if (((unsigned char) *texto & 0xC0) != 0x80) {
            columna_actual++;
        }
    }
}

/* -----------------------------------------------------------------------------
 *  escribir_visible: escribe el texto mostrando los saltos de línea,
 *  tabuladores y retornos de carro como \n, \t y \r, para que una cadena de
 *  varias líneas ocupe un solo renglón en las tablas.
 * -------------------------------------------------------------------------- */
static void escribir_visible(FILE *salida, const char *texto)
{
    for (; *texto != '\0'; texto++) {
        if (*texto == '\n')
            fputs("\\n", salida);
        else if (*texto == '\t')
            fputs("\\t", salida);
        else if (*texto == '\r')
            fputs("\\r", salida);
        else
            fputc(*texto, salida);
    }
}

/* -----------------------------------------------------------------------------
 *  reportar_error: cuenta el error y lo escribe en pantalla y en errores.txt
 *  con la línea y la columna donde empieza, la descripción y el texto que lo
 *  provocó.
 * -------------------------------------------------------------------------- */
static void reportar_error(const char *descripcion, const char *lexema)
{
    total_errores++;

    printf("Error lexico en linea %d, columna %d: %s: ",
           linea_token, columna_token, descripcion);
    escribir_visible(stdout, lexema);
    printf("\n");

    if (archivo_errores != NULL) {
        fprintf(archivo_errores, "Error lexico en linea %d, columna %d: %s: ",
                linea_token, columna_token, descripcion);
        escribir_visible(archivo_errores, lexema);
        fprintf(archivo_errores, "\n");
    }
}

/* -----------------------------------------------------------------------------
 *  nombre_clase: devuelve el nombre de una clase para mostrarlo en la salida.
 * -------------------------------------------------------------------------- */
static const char *nombre_clase(int clase)
{
    switch (clase) {
        case CLASE_OP_ARITMETICO:  return "Op. aritmetico";
        case CLASE_OP_LOGICO:      return "Op. logico";
        case CLASE_OP_RELACIONAL:  return "Op. relacional";
        case CLASE_CONST_ENTERA:   return "Constante entera";
        case CLASE_PAL_RESERVADA:  return "Palabra reservada";
        case CLASE_IDENTIFICADOR:  return "Identificador";
        case CLASE_SIMB_ESPECIAL:  return "Simbolo especial";
        case CLASE_OP_ASIGNACION:  return "Op. asignacion";
        case CLASE_CONST_CADENA:   return "Constante cadena";
        case CLASE_OP_CADENA:      return "Op. sobre cadenas";
        default:                   return "Desconocida";
    }
}

/* -----------------------------------------------------------------------------
 *  escribir_lexema: reconstruye el lexema de un token a partir de su clase y
 *  su valor (catálogos, tablas o el propio valor). El token solo guarda dos
 *  campos; el lexema se muestra únicamente para facilitar la revisión.
 * -------------------------------------------------------------------------- */
static void escribir_lexema(FILE *salida, Token token)
{
    switch (token.clase) {
        case CLASE_OP_ARITMETICO:
        case CLASE_SIMB_ESPECIAL:
            fputc(token.valor, salida);
            break;
        case CLASE_OP_LOGICO:
            fputs(OPERADORES_LOGICOS[token.valor], salida);
            break;
        case CLASE_OP_RELACIONAL:
            fputs(OPERADORES_RELACIONALES[token.valor], salida);
            break;
        case CLASE_CONST_ENTERA:
            fprintf(salida, "%d", token.valor);
            break;
        case CLASE_PAL_RESERVADA:
            fputs(PALABRAS_RESERVADAS[token.valor], salida);
            break;
        case CLASE_IDENTIFICADOR:
            fputs(tabla_simbolos.registros[token.valor].nombre, salida);
            break;
        case CLASE_OP_ASIGNACION:
            fputs(OPERADORES_ASIGNACION[token.valor], salida);
            break;
        case CLASE_CONST_CADENA:
            escribir_visible(salida, tabla_literales.registros[token.valor].dato);
            break;
        case CLASE_OP_CADENA:
            fputs(OPERADORES_CADENA[token.valor], salida);
            break;
    }
}

/* -----------------------------------------------------------------------------
 *  mostrar_tokens: escribe la lista de tokens (clase, valor) en la salida
 *  indicada (pantalla o archivo), con el nombre de la clase y el lexema.
 * -------------------------------------------------------------------------- */
static void mostrar_tokens(FILE *salida)
{
    int i;

    fprintf(salida, "\n==================================================================\n");
    fprintf(salida, " TOKENS (clase, valor)                       total: %d\n", lista_tokens.cantidad);
    fprintf(salida, "==================================================================\n");
    fprintf(salida, " %5s  %5s  %11s   %-18s  %s\n", "No.", "Clase", "Valor", "Componente", "Lexema");
    fprintf(salida, " %5s  %5s  %11s   %-18s  %s\n", "-----", "-----", "-----------",
            "------------------", "------------");

    for (i = 0; i < lista_tokens.cantidad; i++) {
        Token token = lista_tokens.elementos[i];

        fprintf(salida, " %5d  %5d  %11d   %-18s  ",
                i + 1, token.clase, token.valor, nombre_clase(token.clase));
        escribir_lexema(salida, token);
        fprintf(salida, "\n");
    }
}

/* -----------------------------------------------------------------------------
 *  mostrar_tabla_simbolos: escribe la tabla de símbolos en orden de posición
 *  con sus tres campos: posición, nombre y tipo.
 * -------------------------------------------------------------------------- */
static void mostrar_tabla_simbolos(FILE *salida)
{
    int i;
    int ancho = 6;   /* ancho de la columna Nombre, crece con el más largo */

    for (i = 0; i < tabla_simbolos.cantidad; i++) {
        int longitud = (int) strlen(tabla_simbolos.registros[i].nombre);
        if (longitud > ancho)
            ancho = longitud;
    }

    fprintf(salida, "\n==================================================================\n");
    fprintf(salida, " TABLA DE SIMBOLOS                           total: %d\n", tabla_simbolos.cantidad);
    fprintf(salida, "==================================================================\n");
    fprintf(salida, " %8s   %-*s   %4s\n", "Posicion", ancho, "Nombre", "Tipo");
    fprintf(salida, " %8s   %-*s   %4s\n", "--------", ancho, "------", "----");

    for (i = 0; i < tabla_simbolos.cantidad; i++)
        fprintf(salida, " %8d   %-*s   %4d\n",
                tabla_simbolos.registros[i].posicion, ancho,
                tabla_simbolos.registros[i].nombre,
                tabla_simbolos.registros[i].tipo);
}

/* -----------------------------------------------------------------------------
 *  mostrar_tabla_literales: escribe la tabla de literales con sus dos campos:
 *  posición y dato (la cadena, con los saltos de línea visibles como \n).
 * -------------------------------------------------------------------------- */
static void mostrar_tabla_literales(FILE *salida)
{
    int i;

    fprintf(salida, "\n==================================================================\n");
    fprintf(salida, " TABLA DE LITERALES                          total: %d\n", tabla_literales.cantidad);
    fprintf(salida, "==================================================================\n");
    fprintf(salida, " %8s   %s\n", "Posicion", "Dato");
    fprintf(salida, " %8s   %s\n", "--------", "----");

    for (i = 0; i < tabla_literales.cantidad; i++) {
        fprintf(salida, " %8d   ", tabla_literales.registros[i].posicion);
        escribir_visible(salida, tabla_literales.registros[i].dato);
        fprintf(salida, "\n");
    }
}

/* -----------------------------------------------------------------------------
 *  mostrar_atomos: escribe la secuencia de átomos que recibe el analizador
 *  sintáctico, en renglones de 60, y después cada átomo con la línea y la
 *  columna donde empieza y el lexema que lo produjo. El último átomo, $,
 *  marca el fin de la entrada.
 * -------------------------------------------------------------------------- */
static void mostrar_atomos(FILE *salida)
{
    int i;

    fprintf(salida, "\n==================================================================\n");
    fprintf(salida, " SECUENCIA DE ATOMOS                         total: %d\n", lista_atomos.cantidad);
    fprintf(salida, "==================================================================\n ");
    for (i = 0; i < lista_atomos.cantidad; i++) {
        fputc(lista_atomos.elementos[i].simbolo, salida);
        if ((i + 1) % 60 == 0 && i + 1 < lista_atomos.cantidad)
            fprintf(salida, "\n ");
    }
    fprintf(salida, "\n\n %5s  %5s  %5s  %7s   %s\n", "No.", "Atomo", "Linea", "Columna", "Lexema");
    fprintf(salida, " %5s  %5s  %5s  %7s   %s\n", "-----", "-----", "-----", "-------", "------------");

    for (i = 0; i < lista_atomos.cantidad; i++) {
        Atomo atomo = lista_atomos.elementos[i];

        fprintf(salida, " %5d  %5c  %5d  %7d   ",
                i + 1, atomo.simbolo, atomo.linea, atomo.columna);
        escribir_visible(salida, atomo.lexema);
        fprintf(salida, "\n");
    }
}

/* -----------------------------------------------------------------------------
 *  guardar_resultados: escribe los tokens, las dos tablas y los átomos en
 *  tokens.txt, tabla_simbolos.txt, tabla_literales.txt y atomos.txt.
 * -------------------------------------------------------------------------- */
static void guardar_resultados(void)
{
    FILE *archivo;

    archivo = fopen("tokens.txt", "w");
    if (archivo != NULL) {
        mostrar_tokens(archivo);
        fclose(archivo);
    }

    archivo = fopen("tabla_simbolos.txt", "w");
    if (archivo != NULL) {
        mostrar_tabla_simbolos(archivo);
        fclose(archivo);
    }

    archivo = fopen("tabla_literales.txt", "w");
    if (archivo != NULL) {
        mostrar_tabla_literales(archivo);
        fclose(archivo);
    }

    archivo = fopen("atomos.txt", "w");
    if (archivo != NULL) {
        mostrar_atomos(archivo);
        fclose(archivo);
    }

    printf("\nResultados guardados en tokens.txt, tabla_simbolos.txt, "
           "tabla_literales.txt, atomos.txt y errores.txt\n");
}

/* -----------------------------------------------------------------------------
 *  liberar_memoria: libera los nombres, las cadenas y los arreglos dinámicos.
 * -------------------------------------------------------------------------- */
static void liberar_memoria(void)
{
    int i;

    for (i = 0; i < tabla_simbolos.cantidad; i++)
        free(tabla_simbolos.registros[i].nombre);
    for (i = 0; i < tabla_literales.cantidad; i++)
        free(tabla_literales.registros[i].dato);
    for (i = 0; i < lista_atomos.cantidad; i++)
        free((char *) lista_atomos.elementos[i].lexema);

    free(tabla_simbolos.registros);
    free(tabla_literales.registros);
    free(lista_tokens.elementos);
    free(lista_atomos.elementos);
}

/* =============================================================================
 *  main: abre el archivo fuente indicado en la línea de comandos, ejecuta el
 *  análisis léxico con yylex(), muestra los resultados léxicos y la secuencia
 *  de átomos y, solo si no hubo errores léxicos, ejecuta el análisis
 *  sintáctico. Al final guarda los resultados en archivos.
 * ========================================================================== */
int main(int argc, char *argv[])
{
    int errores_sintacticos;

    if (argc != 2) {
        fprintf(stderr, "Uso: %s <archivo_fuente>\n", argv[0]);
        return EXIT_FAILURE;
    }

    yyin = fopen(argv[1], "r");
    if (yyin == NULL) {
        fprintf(stderr, "No se pudo abrir el archivo '%s'.\n", argv[1]);
        return EXIT_FAILURE;
    }
    saltar_bom(yyin);

    archivo_errores = fopen("errores.txt", "w");
    if (archivo_errores == NULL)
        fprintf(stderr, "Aviso: no se pudo crear errores.txt; los errores solo se "
                        "mostraran en pantalla.\n");

    inicializar_tablas();

    printf("Analizando '%s'...\n\n", argv[1]);
    yylex();
    fclose(yyin);

    /* El átomo $ marca el fin de la entrada para el analizador sintáctico. */
    agregar_atomo(FIN_DE_ENTRADA, "(fin de la entrada)", linea_actual, columna_actual);

    if (total_errores == 0) {
        printf("No se encontraron errores lexicos.\n");
        if (archivo_errores != NULL)
            fprintf(archivo_errores, "No se encontraron errores lexicos.\n");
    } else {
        printf("\nTotal de errores lexicos: %d\n", total_errores);
        if (archivo_errores != NULL)
            fprintf(archivo_errores, "\nTotal de errores lexicos: %d\n", total_errores);
    }

    mostrar_tokens(stdout);
    mostrar_tabla_simbolos(stdout);
    mostrar_tabla_literales(stdout);
    mostrar_atomos(stdout);

    /* ---------------- Análisis sintáctico ---------------- */
    printf("\n==================================================================\n");
    printf(" ANALISIS SINTACTICO\n");
    printf("==================================================================\n");
    if (archivo_errores != NULL)
        fprintf(archivo_errores, "\n--- Analisis sintactico ---\n");

    if (total_errores > 0) {
        printf("No se realizo el analisis sintactico porque hubo errores lexicos.\n");
        if (archivo_errores != NULL)
            fprintf(archivo_errores,
                    "No se realizo el analisis sintactico porque hubo errores lexicos.\n");
    } else {
        errores_sintacticos = analizar_sintaxis(lista_atomos.elementos,
                                                lista_atomos.cantidad,
                                                archivo_errores);
        if (errores_sintacticos == 0) {
            printf("El archivo es sintacticamente correcto.\n");
            if (archivo_errores != NULL)
                fprintf(archivo_errores, "El archivo es sintacticamente correcto.\n");
        } else {
            printf("\nTotal de errores sintacticos: %d\n", errores_sintacticos);
            printf("El archivo NO es sintacticamente correcto.\n");
            if (archivo_errores != NULL) {
                fprintf(archivo_errores, "\nTotal de errores sintacticos: %d\n",
                        errores_sintacticos);
                fprintf(archivo_errores, "El archivo NO es sintacticamente correcto.\n");
            }
        }
    }
    if (archivo_errores != NULL)
        fclose(archivo_errores);

    guardar_resultados();

    liberar_memoria();
    return EXIT_SUCCESS;
}
