#pragma once
#include <Arduino.h>
#include <TFT_eSPI.h>

void displayInit();
TFT_eSPI &display();

void touchInit();
// Returns true on a fresh tap with mapped screen coords.
bool touchTap(uint16_t &x, uint16_t &y);
