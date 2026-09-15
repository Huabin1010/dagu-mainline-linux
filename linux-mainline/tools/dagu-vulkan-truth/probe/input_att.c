/* Two-subpass LINEAR input-attachment probe. Included from probe.c. */

static void run_input_att(VkPhysicalDevice pd, VkDevice dev, uint32_t qfi,
                          VkQueue queue, const struct run_cfg *cfg)
{
   char report_path[512];
   snprintf(report_path, sizeof(report_path), "%s/%s.report.txt", cfg->out_dir,
            cfg->name);
   FILE *rep = fopen(report_path, "w");
   if (!rep)
      DIE("fopen %s: %s", report_path, strerror(errno));

   fprintf(rep, "name=%s tiling=%s format=0x%x %ux%u draws=%u mode=input-att\n",
           cfg->name,
           cfg->tiling == VK_IMAGE_TILING_LINEAR ? "LINEAR" : "OPTIMAL",
           (unsigned)cfg->format, cfg->w, cfg->h, cfg->draws);

   VkImageUsageFlags usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                             VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT |
                             VK_IMAGE_USAGE_TRANSFER_SRC_BIT;

   VkImageFormatProperties ip;
   VkResult ifp = vkGetPhysicalDeviceImageFormatProperties(
      pd, cfg->format, VK_IMAGE_TYPE_2D, cfg->tiling, usage, 0, &ip);
   printf("IMAGEFMT[%s] COLOR|INPUT|XFER_SRC tiling=%s -> %d\n", cfg->name,
          cfg->tiling == VK_IMAGE_TILING_LINEAR ? "LINEAR" : "OPTIMAL",
          (int)ifp);
   fprintf(rep, "image_format_props=%d\n", (int)ifp);

   VkImageCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .imageType = VK_IMAGE_TYPE_2D,
      .format = cfg->format,
      .extent = {cfg->w, cfg->h, 1},
      .mipLevels = 1,
      .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT,
      .tiling = cfg->tiling,
      .usage = usage,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
      .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
   };

   VkImage img;
   VkResult ir = vkCreateImage(dev, &ici, NULL, &img);
   printf("CREATE[%s] tiling=%s usage=COLOR|INPUT|XFER_SRC -> %d\n", cfg->name,
          cfg->tiling == VK_IMAGE_TILING_LINEAR ? "LINEAR" : "OPTIMAL",
          (int)ir);
   fprintf(rep, "vkCreateImage=%d\n", (int)ir);
   if (ir != VK_SUCCESS) {
      printf("VERDICT[%s] IMAGE_CREATE_FAILED  (blob refused LINEAR+INPUT_ATT)\n",
             cfg->name);
      fprintf(rep, "verdict=IMAGE_CREATE_FAILED\n");
      fclose(rep);
      return;
   }

   VkMemoryRequirements irq;
   vkGetImageMemoryRequirements(dev, img, &irq);
   uint32_t host_type = find_mem_type(pd, irq.memoryTypeBits,
                                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0);
   uint32_t any_type = find_mem_type(pd, irq.memoryTypeBits, 0, 0);
   if (any_type == UINT32_MAX) {
      for (uint32_t i = 0; i < 32; i++)
         if (irq.memoryTypeBits & (1u << i)) {
            any_type = i;
            break;
         }
   }
   bool image_host_vis = host_type != UINT32_MAX;
   uint32_t img_type = image_host_vis ? host_type : any_type;
   fprintf(rep, "mem_size=%" PRIu64 " mem_type=%u host_visible=%d\n",
           (uint64_t)irq.size, img_type, image_host_vis);

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

   /* Same attachment is color in both subpasses and input in subpass 1.
    * GENERAL keeps the blob from being forced through a layout lie.
    */
   VkAttachmentDescription att = {
      .format = cfg->format,
      .samples = VK_SAMPLE_COUNT_1_BIT,
      .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
      .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
      .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
      .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
      .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
      .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
   };
   VkAttachmentReference color0 = {
      .attachment = 0,
      .layout = VK_IMAGE_LAYOUT_GENERAL,
   };
   VkAttachmentReference color1 = {
      .attachment = 0,
      .layout = VK_IMAGE_LAYOUT_GENERAL,
   };
   VkAttachmentReference input1 = {
      .attachment = 0,
      .layout = VK_IMAGE_LAYOUT_GENERAL,
   };
   VkSubpassDescription subs[2] = {
      {
         .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
         .colorAttachmentCount = 1,
         .pColorAttachments = &color0,
      },
      {
         .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
         .inputAttachmentCount = 1,
         .pInputAttachments = &input1,
         .colorAttachmentCount = 1,
         .pColorAttachments = &color1,
      },
   };
   VkSubpassDependency deps[2] = {
      {
         .srcSubpass = 0,
         .dstSubpass = 1,
         .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
         .dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
         .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
         .dstAccessMask = VK_ACCESS_INPUT_ATTACHMENT_READ_BIT,
         .dependencyFlags = VK_DEPENDENCY_BY_REGION_BIT,
      },
      {
         .srcSubpass = 1,
         .dstSubpass = VK_SUBPASS_EXTERNAL,
         .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
         .dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
         .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
         .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
      },
   };
   VkRenderPassCreateInfo rpci = {
      .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
      .attachmentCount = 1,
      .pAttachments = &att,
      .subpassCount = 2,
      .pSubpasses = subs,
      .dependencyCount = 2,
      .pDependencies = deps,
   };
   VkRenderPass rp;
   VKC(vkCreateRenderPass(dev, &rpci, NULL, &rp));
   fprintf(rep, "renderpass=2_subpass input_att=0\n");

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

   VkDescriptorSetLayoutBinding bind = {
      .binding = 0,
      .descriptorType = VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
      .descriptorCount = 1,
      .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
   };
   VkDescriptorSetLayoutCreateInfo dslci = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      .bindingCount = 1,
      .pBindings = &bind,
   };
   VkDescriptorSetLayout dsl;
   VKC(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));

   VkPipelineLayoutCreateInfo paint_plci = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
   };
   VkPipelineLayout paint_layout;
   VKC(vkCreatePipelineLayout(dev, &paint_plci, NULL, &paint_layout));

   VkPipelineLayoutCreateInfo fetch_plci = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .setLayoutCount = 1,
      .pSetLayouts = &dsl,
   };
   VkPipelineLayout fetch_layout;
   VKC(vkCreatePipelineLayout(dev, &fetch_plci, NULL, &fetch_layout));

   VkDescriptorPoolSize psz = {
      .type = VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
      .descriptorCount = 1,
   };
   VkDescriptorPoolCreateInfo dpci = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
      .maxSets = 1,
      .poolSizeCount = 1,
      .pPoolSizes = &psz,
   };
   VkDescriptorPool dpool;
   VKC(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));
   VkDescriptorSetAllocateInfo dsai = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
      .descriptorPool = dpool,
      .descriptorSetCount = 1,
      .pSetLayouts = &dsl,
   };
   VkDescriptorSet dset;
   VKC(vkAllocateDescriptorSets(dev, &dsai, &dset));
   VkDescriptorImageInfo dii = {
      .imageView = view,
      .imageLayout = VK_IMAGE_LAYOUT_GENERAL,
   };
   VkWriteDescriptorSet wr = {
      .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
      .dstSet = dset,
      .dstBinding = 0,
      .descriptorCount = 1,
      .descriptorType = VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
      .pImageInfo = &dii,
   };
   vkUpdateDescriptorSets(dev, 1, &wr, 0, NULL);

   VkShaderModule vs = mk_shader(dev, (const uint32_t *)vert_spv, vert_spv_len);
   VkShaderModule fs_paint = mk_shader(dev, (const uint32_t *)frag_spv,
                                       frag_spv_len);
   VkShaderModule fs_fetch = mk_shader(dev, (const uint32_t *)fetch_spv,
                                       fetch_spv_len);

   VkPipelineShaderStageCreateInfo paint_st[2] = {
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
       .stage = VK_SHADER_STAGE_VERTEX_BIT,
       .module = vs,
       .pName = "main"},
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
       .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
       .module = fs_paint,
       .pName = "main"},
   };
   VkPipelineShaderStageCreateInfo fetch_st[2] = {
      paint_st[0],
      {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
       .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
       .module = fs_fetch,
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
   VkPipelineColorBlendAttachmentState cba = {.colorWriteMask = 0xf};
   VkPipelineColorBlendStateCreateInfo cb = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      .attachmentCount = 1,
      .pAttachments = &cba,
   };

   VkGraphicsPipelineCreateInfo gp_paint = {
      .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
      .stageCount = 2,
      .pStages = paint_st,
      .pVertexInputState = &vi,
      .pInputAssemblyState = &ia,
      .pViewportState = &vps,
      .pRasterizationState = &rs,
      .pMultisampleState = &ms,
      .pColorBlendState = &cb,
      .layout = paint_layout,
      .renderPass = rp,
      .subpass = 0,
   };
   VkGraphicsPipelineCreateInfo gp_fetch = gp_paint;
   gp_fetch.pStages = fetch_st;
   gp_fetch.layout = fetch_layout;
   gp_fetch.subpass = 1;

   VkPipeline pipe_paint, pipe_fetch;
   VKC(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gp_paint, NULL,
                                 &pipe_paint));
   VKC(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gp_fetch, NULL,
                                 &pipe_fetch));

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
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe_paint);
   for (uint32_t i = 0; i < cfg->draws; i++)
      vkCmdDraw(cmd, 3, 1, 0, 0);
   vkCmdNextSubpass(cmd, VK_SUBPASS_CONTENTS_INLINE);
   vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe_fetch);
   vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, fetch_layout, 0,
                           1, &dset, 0, NULL);
   vkCmdDraw(cmd, 3, 1, 0, 0);
   vkCmdEndRenderPass(cmd);

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
   printf("SUBMIT[%s] ok (subpass0 paint x%u + subpass1 subpassLoad invert)\n",
          cfg->name, cfg->draws);
   fprintf(rep, "submit=ok subpass0_draws=%u subpass1_draws=1\n", cfg->draws);

   if (image_host_vis && cfg->tiling == VK_IMAGE_TILING_LINEAR && sl.rowPitch) {
      void *map = NULL;
      if (vkMapMemory(dev, imgmem, 0, irq.size, 0, &map) == VK_SUCCESS) {
         const uint8_t *base = (const uint8_t *)map + sl.offset;
         analyze_fetch("direct-map", base, cfg->w, cfg->h, (uint32_t)sl.rowPitch,
                       rep);
         analyze_pixels("direct-map-invert", base, cfg->w, cfg->h,
                        (uint32_t)sl.rowPitch, rep, 1);
         char rawp[512];
         snprintf(rawp, sizeof(rawp), "%s/%s.direct.bgra", cfg->out_dir,
                  cfg->name);
         size_t dump_n = (size_t)sl.rowPitch * cfg->h;
         if (dump_n > 16u * 1024u * 1024u)
            dump_n = (size_t)sl.rowPitch * 64;
         dump_raw(rawp, base, dump_n);
         vkUnmapMemory(dev, imgmem);
      } else {
         printf("FETCH[direct-map] MAP_FAILED\n");
         fprintf(rep, "direct_map=failed\n");
      }
   }

   void *bmap = NULL;
   VKC(vkMapMemory(dev, stmem, 0, bufsz, 0, &bmap));
   analyze_fetch("copy-buffer", (const uint8_t *)bmap, cfg->w, cfg->h,
                 cfg->w * 4, rep);
   analyze_pixels("copy-buffer-invert", (const uint8_t *)bmap, cfg->w, cfg->h,
                  cfg->w * 4, rep, 1);
   char rawp[512];
   snprintf(rawp, sizeof(rawp), "%s/%s.copy.rgba", cfg->out_dir, cfg->name);
   dump_raw(rawp, bmap, (size_t)cfg->w * 32 * 4 < (size_t)bufsz
                            ? (size_t)cfg->w * 32 * 4
                            : (size_t)bufsz);
   vkUnmapMemory(dev, stmem);

   fclose(rep);
   printf("REPORT[%s] %s\n", cfg->name, report_path);

   vkDestroyPipeline(dev, pipe_fetch, NULL);
   vkDestroyPipeline(dev, pipe_paint, NULL);
   vkDestroyPipelineLayout(dev, fetch_layout, NULL);
   vkDestroyPipelineLayout(dev, paint_layout, NULL);
   vkDestroyDescriptorPool(dev, dpool, NULL);
   vkDestroyDescriptorSetLayout(dev, dsl, NULL);
   vkDestroyShaderModule(dev, vs, NULL);
   vkDestroyShaderModule(dev, fs_paint, NULL);
   vkDestroyShaderModule(dev, fs_fetch, NULL);
   vkDestroyFramebuffer(dev, fb, NULL);
   vkDestroyRenderPass(dev, rp, NULL);
   vkDestroyImageView(dev, view, NULL);
   vkDestroyImage(dev, img, NULL);
   vkFreeMemory(dev, imgmem, NULL);
   vkDestroyBuffer(dev, staging, NULL);
   vkFreeMemory(dev, stmem, NULL);
   vkDestroyCommandPool(dev, pool, NULL);
}
