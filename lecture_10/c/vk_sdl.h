/* One header for translate-c: Vulkan first, so SDL_vulkan.h sees VULKAN_CORE_H_ and reuses
   Vulkan's own handle types instead of declaring its own. */
#include <vulkan/vulkan.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>
