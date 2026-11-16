/* =============================================================================
 *  PROYECTO 2, PARTE 2  -  ANALIZADOR SINTÁCTICO DESCENDENTE RECURSIVO
 *  parser.h: lo que el analizador léxico (analizador.l) necesita conocer del
 *  analizador sintáctico (parser.c).
 *
 *  Materia:  Compiladores
 *  Equipo:   Baños Monjaraz José Guadalupe
 *            Castañeda Carrasco Luisa Valentina
 *            Solis Espinosa Pedro Alberto
 * ============================================================================= */

#ifndef PARSER_H
#define PARSER_H

#include <stdio.h>

/* Átomo que marca el fin de la entrada. El analizador léxico lo agrega al
   final de la secuencia; corresponde al $ de los conjuntos SIGUIENTE. */
#define FIN_DE_ENTRADA '$'

/* -----------------------------------------------------------------------------
 *  Atomo: un símbolo terminal de la gramática (un solo carácter, según la
 *  tabla del Anexo A) junto con la posición del componente léxico que lo
 *  produjo y su texto, para poder ubicar los errores sintácticos.
 * -------------------------------------------------------------------------- */
typedef struct {
    char        simbolo;    /* el átomo: 'a', 'n', 'v', 'i', ';', 'e', ...   */
    int         linea;      /* línea donde empieza el componente léxico      */
    int         columna;    /* columna donde empieza el componente léxico    */
    const char *lexema;     /* texto del componente, solo para los mensajes  */
} Atomo;

/* -----------------------------------------------------------------------------
 *  analizar_sintaxis: revisa que la secuencia de átomos cumpla la gramática
 *  del lenguaje X. La secuencia debe terminar con FIN_DE_ENTRADA.
 *  Cada error se escribe en pantalla y, si bitacora no es NULL, también en
 *  ese archivo. Devuelve el número de errores sintácticos encontrados.
 * -------------------------------------------------------------------------- */
int analizar_sintaxis(const Atomo *atomos, int cantidad, FILE *bitacora);

#endif
