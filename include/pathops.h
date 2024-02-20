#ifndef PATHOPS_H
#define PATHOPS_H

/**
 * @brief Concatenates two paths together.
 *
 * A new object will be created and you must manage its memory.
 * Both base and tip are borrowed.
 *
 * Inserts an appropriate separator.
 */
char *path_mkcat(const char *base, const char *tip);

#endif // PATHOPS_H
