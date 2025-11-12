#ifdef _WIN32
    // On Windows, always use __declspec for DLL exports (works with all compilers)
    #define DLL_EXPORT __declspec(dllexport)
    #define DLL_IMPORT __declspec(dllimport)
#else
    // On Unix-like systems, use visibility attributes for GCC/Clang
    #if __GNUC__ >= 4 || defined(__clang__)
        #define DLL_EXPORT __attribute__ ((visibility ("default")))
        #define DLL_IMPORT __attribute__ ((visibility ("default")))
    #else
        #define DLL_EXPORT
        #define DLL_IMPORT
    #endif
#endif