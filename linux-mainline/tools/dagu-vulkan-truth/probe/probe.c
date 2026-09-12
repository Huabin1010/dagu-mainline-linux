/*
 * dagu-vk-probe — force vulkan.adreno.so to STORE a color RT as LINEAR
 * or OPTIMAL, then CPU-read the pixels and say whether the write was
 * true row-major or macrotile.
 *
 * Usage:
 *   dagu-vk-probe [--caps-only] [--tiling linear|optimal|both]
 *                 [--w 1024] [--h 1024] [--format rgba8|bgra8]
 *                 [--out-dir DIR] [--draws N] [--load-second]
 *                 [--input-second]
 */
#include <vulkan/vulkan.h>

#include <errno.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "vert.spv.h"
#include "frag.spv.h"
#include "fetch.spv.h"

#define DIE(...)                                                               \
   do {                                                                        \
      fprintf(stderr, "FAIL: ");                                               \
      fprintf(stderr, __VA_ARGS__);                                            \
      fprintf(stderr, "\n");                                                   \
      exit(2);                                                                 \
   } while (0)

#define VKC(expr)                                                              \
   do {                                                                        \
      VkResult _r = (expr);                                                    \
      if (_r != VK_SUCCESS)                                                    \
         DIE("%s -> VkResult %d", #expr, (int)_r);                             \
   } while (0)

static const char *feat_bit(VkFormatFeatureFlags f, VkFormatFeatureFlags bit,
                            const char *name)
{
   return (f & bit) ? name : NULL;
}

static void print_features(const char *tag, VkFormatFeatureFlags f)
{
   const char *names[] = {
      feat_bit(f, VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT, "SAMPLED"),
      feat_bit(f, VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT, "COLOR_ATT"),
      feat_bit(f, VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT, "BLEND"),
      feat_bit(f, VK_FORMAT_FEATURE_BLIT_SRC_BIT, "BLIT_SRC"),
      feat_bit(f, VK_FORMAT_FEATURE_BLIT_DST_BIT, "BLIT_DST"),
      feat_bit(f, VK_FORMAT_FEATURE_TRANSFER_SRC_BIT, "XFER_SRC"),
      feat_bit(f, VK_FORMAT_FEATURE_TRANSFER_DST_BIT, "XFER_DST"),
      feat_bit(f, VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT, "STORAGE"),
   };
   printf("  %s 0x%08x:", tag, (unsigned)f);
   for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++)
      if (names[i])
         printf(" %s", names[i]);
   if (!f)
      printf(" (none)");
   printf("\n");
}

static uint32_t find_mem_type(VkPhysicalDevice pd, uint32_t bits,
                              VkMemoryPropertyFlags want,
                              VkMemoryPropertyFlags extra_ok)
{
   VkPhysicalDeviceMemoryProperties mp;
   vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
      if (!(bits & (1u << i)))
         continue;
      VkMemoryPropertyFlags fl = mp.memoryTypes[i].propertyFlags;
      if ((fl & want) == want)
         return i;
   }
   (void)extra_ok;
   return UINT32_MAX;
}

static VkShaderModule mk_shader(VkDevice dev, const uint32_t *words, size_t bytes)
{
   VkShaderModuleCreateInfo ci = {
      .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
      .codeSize = bytes,
      .pCode = words,
   };
   VkShaderModule m;
   VKC(vkCreateShaderModule(dev, &ci, NULL, &m));
   return m;
}

struct run_cfg {
   uint32_t w, h;
   VkFormat format;
   VkImageTiling tiling;
   const char *name;
   const char *out_dir;
   uint32_t draws;
   int load_second;
   int input_second;
};

static int expected_at(uint32_t x, uint32_t y, uint8_t *r, uint8_t *g,
                       uint8_t *b)
{
   *r = (uint8_t)(x & 255u);
   *g = (uint8_t)(y & 255u);
   *b = (uint8_t)((x ^ y) & 255u);
   return 0;
}

static void analyze_pixels(const char *tag, const uint8_t *px, uint32_t w,
                           uint32_t h, uint32_t pitch, FILE *rep, int invert_b)
{
   uint64_t ok = 0, bad = 0, checked = 0;
   uint32_t first_bad_x = 0, first_bad_y = 0;
   uint8_t first_got[4] = {0}, first_exp[4] = {0};
   bool have_bad = false;
   /* Sample a dense grid plus a 32px-tile lattice. */
   for (uint32_t y = 0; y < h; y++) {
      for (uint32_t x = 0; x < w; x++) {
         if ((x & 7) && (y & 7) && (x % 32) && (y % 32))
            continue;
         const uint8_t *p = px + (size_t)y * pitch + (size_t)x * 4;
         uint8_t er, eg, eb;
         expected_at(x, y, &er, &eg, &eb);
         if (invert_b)
            eb = (uint8_t)(255u - eb);
         checked++;
         if (p[0] == er && p[1] == eg && p[2] == eb) {
            ok++;
         } else {
            bad++;
            if (!have_bad) {
               have_bad = true;
               first_bad_x = x;
               first_bad_y = y;
               first_got[0] = p[0];
               first_got[1] = p[1];
               first_got[2] = p[2];
               first_got[3] = p[3];
               first_exp[0] = er;
               first_exp[1] = eg;
               first_exp[2] = eb;
               first_exp[3] = 255;
            }
         }
      }
   }

   double ratio = checked ? (double)ok / (double)checked : 0.0;
   const char *verdict;
   if (invert_b)
      verdict = (bad == 0) ? "FETCH_OK" : (ratio < 0.15 ? "FETCH_BAD" : "FETCH_PARTIAL");
   else
      verdict = (bad == 0) ? "TRUE_LINEAR" : (ratio < 0.15 ? "MACROTILE_OR_GARBAGE" : "PARTIAL_MISMATCH");
   printf("PIXEL[%s] checked=%" PRIu64 " ok=%" PRIu64 " bad=%" PRIu64
          " match=%.4f verdict=%s\n",
          tag, checked, ok, bad, ratio, verdict);
   if (have_bad)
      printf("PIXEL[%s] first_bad=(%u,%u) got=%02x%02x%02x%02x exp=%02x%02x%02x%02x\n",
             tag, first_bad_x, first_bad_y, first_got[0], first_got[1],
             first_got[2], first_got[3], first_exp[0], first_exp[1],
             first_exp[2], first_exp[3]);
   if (rep) {
      fprintf(rep, "pixel_source=%s checked=%" PRIu64 " ok=%" PRIu64
                   " bad=%" PRIu64 " match=%.6f verdict=%s\n",
              tag, checked, ok, bad, ratio, verdict);
      if (have_bad)
         fprintf(rep,
                 "first_bad x=%u y=%u got=%02x%02x%02x%02x exp=%02x%02x%02x%02x\n",
                 first_bad_x, first_bad_y, first_got[0], first_got[1],
                 first_got[2], first_got[3], first_exp[0], first_exp[1],
                 first_exp[2], first_exp[3]);
   }
}

static void analyze_fetch(const char *tag, const uint8_t *px, uint32_t w,
                          uint32_t h, uint32_t pitch, FILE *rep)
{
   uint64_t ok_inv = 0, ok_paint = 0, ok_black = 0, checked = 0;
   uint32_t first_x = 0, first_y = 0;
   uint8_t first[4] = {0};
   bool have = false;

   for (uint32_t y = 0; y < h; y++) {
      for (uint32_t x = 0; x < w; x++) {
         if ((x & 7) && (y & 7) && (x % 32) && (y % 32))
            continue;
         const uint8_t *p = px + (size_t)y * pitch + (size_t)x * 4;
         uint8_t er, eg, eb;
         expected_at(x, y, &er, &eg, &eb);
         checked++;
         if (p[0] == er && p[1] == eg && p[2] == (uint8_t)(255u - eb))
            ok_inv++;
         else if (p[0] == er && p[1] == eg && p[2] == eb)
            ok_paint++;
         else if (p[0] == 0 && p[1] == 0 && p[2] == 255)
            ok_black++;
         if (!have &&
             !(p[0] == er && p[1] == eg && p[2] == (uint8_t)(255u - eb))) {
            have = true;
            first_x = x;
            first_y = y;
            first[0] = p[0];
            first[1] = p[1];
            first[2] = p[2];
            first[3] = p[3];
         }
      }
   }

   const char *verdict = "FETCH_MIXED";
   if (checked && ok_inv == checked)
      verdict = "FETCH_OK";
   else if (checked && ok_paint == checked)
      verdict = "FETCH_SKIPPED_PAINT";
   else if (checked && ok_black * 20 >= checked * 17)
      verdict = "FETCH_BLACK";
   else if (checked && ok_inv * 20 >= checked * 17)
      verdict = "FETCH_MOSTLY_OK";

   printf("FETCH[%s] checked=%" PRIu64 " invert=%" PRIu64 " paint=%" PRIu64
          " black=%" PRIu64 " verdict=%s\n",
          tag, checked, ok_inv, ok_paint, ok_black, verdict);
   if (have)
      printf("FETCH[%s] first_miss=(%u,%u) got=%02x%02x%02x%02x\n", tag, first_x,
             first_y, first[0], first[1], first[2], first[3]);
   if (rep) {
      fprintf(rep,
              "fetch_source=%s checked=%" PRIu64 " invert=%" PRIu64
              " paint=%" PRIu64 " black=%" PRIu64 " verdict=%s\n",
              tag, checked, ok_inv, ok_paint, ok_black, verdict);
      if (have)
         fprintf(rep, "first_miss x=%u y=%u got=%02x%02x%02x%02x\n", first_x,
                 first_y, first[0], first[1], first[2], first[3]);
   }
}

static void dump_raw(const char *path, const uint8_t *px, size_t n)
{
   FILE *f = fopen(path, "wb");
   if (!f) {
      fprintf(stderr, "warn: cannot write %s: %s\n", path, strerror(errno));
      return;
   }
   fwrite(px, 1, n, f);
   fclose(f);
}

#include "input_att.c"

static void run_one(VkPhysicalDevice pd, VkDevice dev, uint32_t qfi,
                    VkQueue queue, const struct run_cfg *cfg)
{
   char report_path[512];
   snprintf(report_path, sizeof(report_path), "%s/%s.report.txt", cfg->out_dir,
            cfg->name);
   FILE *rep = fopen(report_path, "w");
   if (!rep)
      DIE("fopen %s: %s", report_path, strerror(errno));

   fprintf(rep, "name=%s tiling=%s format=0x%x %ux%u draws=%u\n", cfg->name,
           cfg->tiling == VK_IMAGE_TILING_LINEAR ? "LINEAR" : "OPTIMAL",
           (unsigned)cfg->format, cfg->w, cfg->h, cfg->draws);

   VkImageCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .imageType = VK_IMAGE_TYPE_2D,
      .format = cfg->format,
      .extent = {cfg->w, cfg->h, 1},
      .mipLevels = 1,
      .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT,
      .tiling = cfg->tiling,
      .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
      .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
   };

   VkImage img;
   VkResult ir = vkCreateImage(dev, &ici, NULL, &img);
   printf("CREATE[%s] tiling=%s usage=COLOR_ATT|XFER_SRC -> %d\n", cfg->name,
          cfg->tiling == VK_IMAGE_TILING_LINEAR ? "LINEAR" : "OPTIMAL", (int)ir);
   fprintf(rep, "vkCreateImage=%d\n", (int)ir);
   if (ir != VK_SUCCESS) {
      printf("VERDICT[%s] IMAGE_CREATE_FAILED  (blob refused this tiling as RT)\n",
             cfg->name);
      fprintf(rep, "verdict=IMAGE_CREATE_FAILED\n");
      fclose(rep);
      return;
   }

   VkMemoryRequirements irq;
   vkGetImageMemoryRequirements(dev, img, &irq);
   printf("MEMREQ[%s] size=%" PRIu64 " align=%" PRIu64 " types=0x%x\n", cfg->name,
          (uint64_t)irq.size, (uint64_t)irq.alignment, irq.memoryTypeBits);
   fprintf(rep, "mem_size=%" PRIu64 " align=%" PRIu64 " types=0x%x\n",
           (uint64_t)irq.size, (uint64_t)irq.alignment, irq.memoryTypeBits);

   uint32_t host_type = find_mem_type(pd, irq.memoryTypeBits,
                                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0);
   uint32_t any_type = find_mem_type(pd, irq.memoryTypeBits, 0, 0);
   if (any_type == UINT32_MAX) {
      /* last resort: first set bit */
      for (uint32_t i = 0; i < 32; i++)
         if (irq.memoryTypeBits & (1u << i)) {
            any_type = i;
            break;
         }
   }
   bool image_host_vis = host_type != UINT32_MAX;
   uint32_t img_type = image_host_vis ? host_type : any_type;
   printf("MEMTYPE[%s] index=%u host_visible=%d\n", cfg->name, img_type,
          image_host_vis);
   fprintf(rep, "mem_type=%u host_visible=%d\n", img_type, image_host_vis);

   VkMemoryAllocateInfo mai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = irq.size,
      .memoryTypeIndex = img_type,
   };
   VkDeviceMemory imgmem;
   VKC(vkAllocateMemory(dev, &mai, NULL, &imgmem));
   VKC(vkBindImageMemory(dev, img, imgmem, 0));

   VkSubresourceLayout sl = {0};
   if (cfg->tiling == VK_IMAGE_TILING_LINEAR) {
      VkImageSubresource sr = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT};
      vkGetImageSubresourceLayout(dev, img, &sr, &sl);
      printf("LAYOUT[%s] offset=%" PRIu64 " pitch=%" PRIu64 " size=%" PRIu64 "\n",
             cfg->name, (uint64_t)sl.offset, (uint64_t)sl.rowPitch,
             (uint64_t)sl.size);
      fprintf(rep, "linear_offset=%" PRIu64 " rowPitch=%" PRIu64 " size=%" PRIu64
                   "\n",
              (uint64_t)sl.offset, (uint64_t)sl.rowPitch, (uint64_t)sl.size);
   }

   VkImageViewCreateInfo vci = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      .image = img,
      .viewType = VK_IMAGE_VIEW_TYPE_2D,
      .format = cfg->format,
      .subresourceRange = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                           .levelCount = 1,
                           .layerCount = 1},
   };
   VkImageView view;
   VKC(vkCreateImageView(dev, &vci, NULL, &view));

   VkAttachmentDescription att = {
      .format = cfg->format,
      .samples = VK_SAMPLE_COUNT_1_BIT,
      .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
      .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
      .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
      .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
      .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
      .finalLayout = cfg->load_second ? VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
                                      : VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
   };
   VkAttachmentReference color_ref = {
      .attachment = 0,
      .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
   };
   VkSubpassDescription sub = {
      .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
      .colorAttachmentCount = 1,
      .pColorAttachments = &color_ref,
   };
   VkSubpassDependency dep = {
      .srcSubpass = 0,
      .dstSubpass = VK_SUBPASS_EXTERNAL,
      .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
      .dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
      .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
   };
   VkRenderPassCreateInfo rpci = {
      .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
      .attachmentCount = 1,
      .pAttachments = &att,
      .subpassCount = 1,
      .pSubpasses = &sub,
      .dependencyCount = 1,
      .pDependencies = &dep,
   };
   VkRenderPass rp;
   VKC(vkCreateRenderPass(dev, &rpci, NULL, &rp));

   VkFramebufferCreateInfo fbci = {
      .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
      .renderPass = rp,
      .attachmentCount = 1,
      .pAttachments = &view,
      .width = cfg->w,
      .height = cfg->h,
      .layers = 1,
   };
   VkFramebuffer fb;
   VKC(vkCreateFramebuffer(dev, &fbci, NULL, &fb));

   VkShaderModule vs = mk_shader(dev, (const uint32_t *)vert_spv, vert_spv_len);
   VkShaderModule fs = mk_shader(dev, (const uint32_t *)frag_spv, frag_spv_len);
   VkPipelineLayoutCreateInfo plci = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
   };
   VkPipelineLayout layout;
   VKC(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

   VkPipelineShaderStageCreateInfo stages[2] = {
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
       .stage = VK_SHADER_STAGE_VERTEX_BIT,
       .module = vs,
       .pName = "main"},
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
       .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
       .module = fs,
       .pName = "main"},
   };
   VkPipelineVertexInputStateCreateInfo vi = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
   };
   VkPipelineInputAssemblyStateCreateInfo ia = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
      .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
   };
   VkViewport vp = {0, 0, (float)cfg->w, (float)cfg->h, 0, 1};
   VkRect2D sc = {{0, 0}, {cfg->w, cfg->h}};
   VkPipelineViewportStateCreateInfo vps = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
      .viewportCount = 1,
      .pViewports = &vp,
      .scissorCount = 1,
      .pScissors = &sc,
   };
   VkPipelineRasterizationStateCreateInfo rs = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
      .polygonMode = VK_POLYGON_MODE_FILL,
      .cullMode = VK_CULL_MODE_NONE,
      .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
      .lineWidth = 1.0f,
   };
   VkPipelineMultisampleStateCreateInfo ms = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
      .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
   };
   VkPipelineColorBlendAttachmentState cba = {
      .colorWriteMask = 0xf,
   };
   VkPipelineColorBlendStateCreateInfo cb = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      .attachmentCount = 1,
      .pAttachments = &cba,
   };
   VkGraphicsPipelineCreateInfo gpci = {
      .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
      .stageCount = 2,
      .pStages = stages,
      .pVertexInputState = &vi,
      .pInputAssemblyState = &ia,
      .pViewportState = &vps,
      .pRasterizationState = &rs,
      .pMultisampleState = &ms,
      .pColorBlendState = &cb,
      .layout = layout,
      .renderPass = rp,
      .subpass = 0,
   };
   VkPipeline pipe;
   VKC(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL, &pipe));

   /* staging buffer for copy readback */
   VkDeviceSize bufsz = (VkDeviceSize)cfg->w * cfg->h * 4;
   VkBufferCreateInfo bci = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = bufsz,
      .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
   };
   VkBuffer staging;
   VKC(vkCreateBuffer(dev, &bci, NULL, &staging));
   VkMemoryRequirements brq;
   vkGetBufferMemoryRequirements(dev, staging, &brq);
   uint32_t st_type = find_mem_type(pd, brq.memoryTypeBits,
                                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                       VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                    0);
   if (st_type == UINT32_MAX)
      st_type = find_mem_type(pd, brq.memoryTypeBits,
                              VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0);
   if (st_type == UINT32_MAX)
      DIE("no HOST_VISIBLE memory for staging");
   VkMemoryAllocateInfo smai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = brq.size,
      .memoryTypeIndex = st_type,
   };
   VkDeviceMemory stmem;
   VKC(vkAllocateMemory(dev, &smai, NULL, &stmem));
   VKC(vkBindBufferMemory(dev, staging, stmem, 0));

   VkCommandPoolCreateInfo cpci = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .queueFamilyIndex = qfi,
   };
   VkCommandPool pool;
   VKC(vkCreateCommandPool(dev, &cpci, NULL, &pool));
   VkCommandBufferAllocateInfo cbai = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 1,
   };
   VkCommandBuffer cmd;
   VKC(vkAllocateCommandBuffers(dev, &cbai, &cmd));
   VkCommandBufferBeginInfo bi = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
   };
   VKC(vkBeginCommandBuffer(cmd, &bi));

   VkClearValue clear = {.color = {.float32 = {0, 0, 0, 1}}};
   VkRenderPassBeginInfo rpbi = {
      .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
      .renderPass = rp,
      .framebuffer = fb,
      .renderArea = {{0, 0}, {cfg->w, cfg->h}},
      .clearValueCount = 1,
      .pClearValues = &clear,
   };
   vkCmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
   for (uint32_t i = 0; i < cfg->draws; i++)
      vkCmdDraw(cmd, 3, 1, 0, 0);
   vkCmdEndRenderPass(cmd);

   VkRenderPass rp_load = VK_NULL_HANDLE;
   VkFramebuffer fb_load = VK_NULL_HANDLE;
   VkPipeline pipe_load = VK_NULL_HANDLE;
   if (cfg->load_second) {
      VkAttachmentDescription att_load = att;
      att_load.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
      att_load.initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
      att_load.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
      VkRenderPassCreateInfo rpci_load = rpci;
      rpci_load.pAttachments = &att_load;
      VKC(vkCreateRenderPass(dev, &rpci_load, NULL, &rp_load));
      VkFramebufferCreateInfo fbci_load = fbci;
      fbci_load.renderPass = rp_load;
      VKC(vkCreateFramebuffer(dev, &fbci_load, NULL, &fb_load));
      VkGraphicsPipelineCreateInfo gpci_load = gpci;
      gpci_load.renderPass = rp_load;
      VKC(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci_load, NULL,
                                    &pipe_load));
      VkRenderPassBeginInfo rpbi_load = {
         .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
         .renderPass = rp_load,
         .framebuffer = fb_load,
         .renderArea = {{0, 0}, {cfg->w, cfg->h}},
      };
      vkCmdBeginRenderPass(cmd, &rpbi_load, VK_SUBPASS_CONTENTS_INLINE);
      vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe_load);
      for (uint32_t i = 0; i < cfg->draws; i++)
         vkCmdDraw(cmd, 3, 1, 0, 0);
      vkCmdEndRenderPass(cmd);
      fprintf(rep, "second_pass=LOAD+STORE draws=%u\n", cfg->draws);
   }

   VkBufferImageCopy copy = {
      .imageSubresource = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                           .layerCount = 1},
      .imageExtent = {cfg->w, cfg->h, 1},
   };
   vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                          staging, 1, &copy);
   VKC(vkEndCommandBuffer(cmd));

   VkSubmitInfo si = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 1,
      .pCommandBuffers = &cmd,
   };
   VKC(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
   VKC(vkQueueWaitIdle(queue));
   printf("SUBMIT[%s] ok (CLEAR+STORE%s + copy)\n", cfg->name,
          cfg->load_second ? " + LOAD+STORE" : "");
   fprintf(rep, "submit=ok\n");

   /* 1) Direct map of LINEAR image — this is the hardware-truth read. */
   if (image_host_vis && cfg->tiling == VK_IMAGE_TILING_LINEAR && sl.rowPitch) {
      void *map = NULL;
      if (vkMapMemory(dev, imgmem, 0, irq.size, 0, &map) == VK_SUCCESS) {
         const uint8_t *base = (const uint8_t *)map + sl.offset;
         analyze_pixels("direct-map", base, cfg->w, cfg->h, (uint32_t)sl.rowPitch,
                        rep, 0);
         char rawp[512];
         snprintf(rawp, sizeof(rawp), "%s/%s.direct.bgra", cfg->out_dir,
                  cfg->name);
         /* dump first 64 rows only if huge; else full */
         size_t dump_n = (size_t)sl.rowPitch * cfg->h;
         if (dump_n > 16u * 1024u * 1024u)
            dump_n = (size_t)sl.rowPitch * 64;
         dump_raw(rawp, base, dump_n);
         vkUnmapMemory(dev, imgmem);
      } else {
         printf("PIXEL[direct-map] MAP_FAILED\n");
         fprintf(rep, "direct_map=failed\n");
      }
   } else if (cfg->tiling == VK_IMAGE_TILING_LINEAR) {
      printf("PIXEL[direct-map] SKIPPED (image memory not HOST_VISIBLE)\n");
      fprintf(rep, "direct_map=skipped_not_host_visible\n");
   }

   /* 2) Copy-to-buffer. Blob may destile on this path — weaker signal. */
   void *bmap = NULL;
   VKC(vkMapMemory(dev, stmem, 0, bufsz, 0, &bmap));
   analyze_pixels("copy-buffer", (const uint8_t *)bmap, cfg->w, cfg->h, cfg->w * 4,
                  rep, 0);
   char rawp[512];
   snprintf(rawp, sizeof(rawp), "%s/%s.copy.rgba", cfg->out_dir, cfg->name);
   dump_raw(rawp, bmap, (size_t)cfg->w * 32 * 4 < (size_t)bufsz
                            ? (size_t)cfg->w * 32 * 4
                            : (size_t)bufsz);
   vkUnmapMemory(dev, stmem);

   fclose(rep);
   printf("REPORT[%s] %s\n", cfg->name, report_path);

   if (pipe_load)
      vkDestroyPipeline(dev, pipe_load, NULL);
   if (fb_load)
      vkDestroyFramebuffer(dev, fb_load, NULL);
   if (rp_load)
      vkDestroyRenderPass(dev, rp_load, NULL);
   vkDestroyPipeline(dev, pipe, NULL);
   vkDestroyPipelineLayout(dev, layout, NULL);
   vkDestroyShaderModule(dev, vs, NULL);
   vkDestroyShaderModule(dev, fs, NULL);
   vkDestroyFramebuffer(dev, fb, NULL);
   vkDestroyRenderPass(dev, rp, NULL);
   vkDestroyImageView(dev, view, NULL);
   vkDestroyImage(dev, img, NULL);
   vkFreeMemory(dev, imgmem, NULL);
   vkDestroyBuffer(dev, staging, NULL);
   vkFreeMemory(dev, stmem, NULL);
   vkDestroyCommandPool(dev, pool, NULL);
}

static void dump_format_caps(VkPhysicalDevice pd, VkFormat fmt, const char *fn)
{
   VkFormatProperties fp;
   vkGetPhysicalDeviceFormatProperties(pd, fmt, &fp);
   printf("FORMAT %s (0x%x)\n", fn, (unsigned)fmt);
   print_features("linearTiling", fp.linearTilingFeatures);
   print_features("optimalTiling", fp.optimalTilingFeatures);
   print_features("buffer      ", fp.bufferFeatures);

   VkImageTiling tiles[] = {VK_IMAGE_TILING_LINEAR, VK_IMAGE_TILING_OPTIMAL};
   const char *tn[] = {"LINEAR", "OPTIMAL"};
   for (int i = 0; i < 2; i++) {
      VkImageFormatProperties ip;
      VkResult r = vkGetPhysicalDeviceImageFormatProperties(
         pd, fmt, VK_IMAGE_TYPE_2D, tiles[i],
         VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
         0, &ip);
      printf("  ImageFormat[%s COLOR_ATT|XFER_SRC] -> %d", tn[i], (int)r);
      if (r == VK_SUCCESS)
         printf(" max=%ux%u samples=0x%x\n", ip.maxExtent.width,
                ip.maxExtent.height, ip.sampleCounts);
      else
         printf(" (not supported)\n");
      r = vkGetPhysicalDeviceImageFormatProperties(
         pd, fmt, VK_IMAGE_TYPE_2D, tiles[i],
         VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
            VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT |
            VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
         0, &ip);
      printf("  ImageFormat[%s COLOR_ATT|INPUT_ATT|XFER_SRC] -> %d", tn[i],
             (int)r);
      if (r == VK_SUCCESS)
         printf(" max=%ux%u samples=0x%x\n", ip.maxExtent.width,
                ip.maxExtent.height, ip.sampleCounts);
      else
         printf(" (not supported)\n");
   }
}

int main(int argc, char **argv)
{
   bool caps_only = false;
   bool do_linear = true, do_optimal = true;
   uint32_t w = 1024, h = 1024, draws = 1;
   int load_second = 0;
   int input_second = 0;
   VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
   const char *out_dir = "/data/local/tmp/dagu-vulkan-truth";

   for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--caps-only"))
         caps_only = true;
      else if (!strcmp(argv[i], "--tiling") && i + 1 < argc) {
         i++;
         if (!strcmp(argv[i], "linear")) {
            do_linear = true;
            do_optimal = false;
         } else if (!strcmp(argv[i], "optimal")) {
            do_linear = false;
            do_optimal = true;
         } else {
            do_linear = do_optimal = true;
         }
      } else if (!strcmp(argv[i], "--w") && i + 1 < argc)
         w = (uint32_t)atoi(argv[++i]);
      else if (!strcmp(argv[i], "--h") && i + 1 < argc)
         h = (uint32_t)atoi(argv[++i]);
      else if (!strcmp(argv[i], "--format") && i + 1 < argc) {
         i++;
         if (!strcmp(argv[i], "bgra8"))
            fmt = VK_FORMAT_B8G8R8A8_UNORM;
         else
            fmt = VK_FORMAT_R8G8B8A8_UNORM;
      }       else if (!strcmp(argv[i], "--out-dir") && i + 1 < argc)
         out_dir = argv[++i];
      else if (!strcmp(argv[i], "--draws") && i + 1 < argc)
         draws = (uint32_t)atoi(argv[++i]);
      else if (!strcmp(argv[i], "--load-second"))
         load_second = 1;
      else if (!strcmp(argv[i], "--input-second"))
         input_second = 1;
      else if (!strcmp(argv[i], "--help")) {
         fprintf(stderr,
                 "dagu-vk-probe [--caps-only] [--tiling linear|optimal|both] "
                 "[--w N] [--h N] [--format rgba8|bgra8] [--out-dir DIR] "
                 "[--draws N] [--load-second] [--input-second]\n");
         return 0;
      }
   }

   mkdir(out_dir, 0755);

   VkApplicationInfo app = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "dagu-vk-probe",
      .applicationVersion = 1,
      .pEngineName = "none",
      .engineVersion = 1,
      .apiVersion = VK_API_VERSION_1_1,
   };
   VkInstanceCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &app,
   };
   VkInstance inst;
   VKC(vkCreateInstance(&ici, NULL, &inst));

   uint32_t ndev = 0;
   VKC(vkEnumeratePhysicalDevices(inst, &ndev, NULL));
   if (!ndev)
      DIE("no physical devices");
   VkPhysicalDevice *devs = calloc(ndev, sizeof(*devs));
   VKC(vkEnumeratePhysicalDevices(inst, &ndev, devs));
   VkPhysicalDevice pd = devs[0];
   VkPhysicalDeviceProperties props;
   vkGetPhysicalDeviceProperties(pd, &props);
   printf("DEVICE %s\n", props.deviceName);
   printf("  api=%u.%u.%u vendor=0x%x device=0x%x type=%u\n",
          VK_VERSION_MAJOR(props.apiVersion),
          VK_VERSION_MINOR(props.apiVersion),
          VK_VERSION_PATCH(props.apiVersion), props.vendorID, props.deviceID,
          props.deviceType);
   printf("  driver=0x%x\n", props.driverVersion);

   uint32_t nlayer = 0;
   vkEnumerateDeviceLayerProperties(pd, &nlayer, NULL);
   printf("  device_layers=%u\n", nlayer);

   dump_format_caps(pd, VK_FORMAT_R8G8B8A8_UNORM, "R8G8B8A8_UNORM");
   dump_format_caps(pd, VK_FORMAT_B8G8R8A8_UNORM, "B8G8R8A8_UNORM");

   if (caps_only) {
      vkDestroyInstance(inst, NULL);
      free(devs);
      return 0;
   }

   uint32_t nqf = 0;
   vkGetPhysicalDeviceQueueFamilyProperties(pd, &nqf, NULL);
   VkQueueFamilyProperties *qfp = calloc(nqf, sizeof(*qfp));
   vkGetPhysicalDeviceQueueFamilyProperties(pd, &nqf, qfp);
   uint32_t qfi = UINT32_MAX;
   for (uint32_t i = 0; i < nqf; i++) {
      if (qfp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
         qfi = i;
         break;
      }
   }
   if (qfi == UINT32_MAX)
      DIE("no graphics queue");
   float prio = 1.0f;
   VkDeviceQueueCreateInfo dq = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = qfi,
      .queueCount = 1,
      .pQueuePriorities = &prio,
   };
   VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &dq,
   };
   VkDevice dev;
   VKC(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue queue;
   vkGetDeviceQueue(dev, qfi, 0, &queue);

   struct run_cfg cfg = {
      .w = w,
      .h = h,
      .format = fmt,
      .out_dir = out_dir,
      .draws = draws ? draws : 1,
      .load_second = load_second,
      .input_second = input_second,
   };
   if (do_linear) {
      cfg.tiling = VK_IMAGE_TILING_LINEAR;
      cfg.name = input_second ? "linear_input" : "linear";
      if (input_second)
         run_input_att(pd, dev, qfi, queue, &cfg);
      else
         run_one(pd, dev, qfi, queue, &cfg);
   }
   if (do_optimal) {
      cfg.tiling = VK_IMAGE_TILING_OPTIMAL;
      cfg.name = input_second ? "optimal_input" : "optimal";
      if (input_second)
         run_input_att(pd, dev, qfi, queue, &cfg);
      else
         run_one(pd, dev, qfi, queue, &cfg);
   }

   vkDestroyDevice(dev, NULL);
   vkDestroyInstance(inst, NULL);
   free(devs);
   free(qfp);
   const char *pause = getenv("DAGU_HEIST_PAUSE");
   if (pause && pause[0] && strcmp(pause, "0") != 0) {
      int sec = atoi(pause);
      if (sec <= 0)
         sec = 30;
      fprintf(stderr, "HEIST_PAUSE pid=%d %ds\n", getpid(), sec);
      sleep((unsigned)sec);
   }
   printf("DONE\n");
   return 0;
}
