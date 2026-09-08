#include <inttypes.h>
#include <stdlib.h>
#include <windows.h>

typedef char pointer_width_matches_target[
    sizeof(void *) * 8 == EXPECTED_POINTER_BITS ? 1 : -1];

int main(void) {
    return 0;
}
