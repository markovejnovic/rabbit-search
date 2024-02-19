#ifndef PATHOPS_H
#define PATHOPS_H

/**
 * @brief Concatenates two paths together.
 * 
 * A new object will be created and you must manage its memory.
 * Both l and r are borrowed.
 * 
 * Inserts an appropriate separator.
 */
char* path_mkcat(const char* l, const char* r);

#endif // PATHOPS_H