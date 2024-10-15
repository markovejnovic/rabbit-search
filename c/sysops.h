#pragma once

/**
 * @brief Pin the current thread to a specific core.
 */
int pinThreadToCore(int core_id);

/**
 * @brief Query the system for the total number of CPUs.
 */
int getNumCpus(void);
