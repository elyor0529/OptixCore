
/*
 * Copyright (c) 2008 - 2009 NVIDIA Corporation.  All rights reserved.
 *
 * NVIDIA Corporation and its licensors retain all intellectual property and proprietary
 * rights in and to this software, related documentation and any modifications thereto.
 * Any use, reproduction, disclosure or distribution of this software and related
 * documentation without an express license agreement from NVIDIA Corporation is strictly
 * prohibited.
 *
 * TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, THIS SOFTWARE IS PROVIDED *AS IS*
 * AND NVIDIA AND ITS SUPPLIERS DISCLAIM ALL WARRANTIES, EITHER EXPRESS OR IMPLIED,
 * INCLUDING, BUT NOT LIMITED TO, IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE.  IN NO EVENT SHALL NVIDIA OR ITS SUPPLIERS BE LIABLE FOR ANY
 * SPECIAL, INCIDENTAL, INDIRECT, OR CONSEQUENTIAL DAMAGES WHATSOEVER (INCLUDING, WITHOUT
 * LIMITATION, DAMAGES FOR LOSS OF BUSINESS PROFITS, BUSINESS INTERRUPTION, LOSS OF
 * BUSINESS INFORMATION, OR ANY OTHER PECUNIARY LOSS) ARISING OUT OF THE USE OF OR
 * INABILITY TO USE THIS SOFTWARE, EVEN IF NVIDIA HAS BEEN ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGES
 */

#include "tutorial.h"

rtDeclareVariable(float3, geometric_normal, attribute geometric_normal, ); 
rtDeclareVariable(float3, shading_normal,   attribute shading_normal, ); 

rtDeclareVariable(PerRayData_radiance, prd_radiance, rtPayload, );
rtDeclareVariable(PerRayData_shadow,   prd_shadow,   rtPayload, );

rtDeclareVariable(optix::Ray, ray,          rtCurrentRay, );
rtDeclareVariable(float,      t_hit,        rtIntersectionDistance, );
rtDeclareVariable(uint2,      launch_index, rtLaunchIndex, );

rtDeclareVariable(unsigned int, radiance_ray_type, , );
rtDeclareVariable(unsigned int, shadow_ray_type , , );
rtDeclareVariable(float,        scene_epsilon, , );
rtDeclareVariable(rtObject,     top_object, , );


//
// Pinhole camera implementation
//
rtDeclareVariable(float3,        eye, , );
rtDeclareVariable(float3,        U, , );
rtDeclareVariable(float3,        V, , );
rtDeclareVariable(float3,        W, , );
rtDeclareVariable(float3,        bad_color, , );
rtBuffer<uchar4, 2>              output_buffer;

RT_PROGRAM void pinhole_camera()
{
  size_t2 screen = output_buffer.size();

  float2 d = make_float2(launch_index) / make_float2(screen) * 2.f - 1.f;
  float3 ray_origin = eye;
  float3 ray_direction = normalize(d.x*U + d.y*V + W);

  optix::Ray ray(ray_origin, ray_direction, radiance_ray_type, scene_epsilon );

  PerRayData_radiance prd;
  prd.importance = 1.f;
  prd.depth = 0;

  rtTrace(top_object, ray, prd);

  output_buffer[launch_index] = make_color( prd.result );
}


//
// Environment map background
//
rtTextureSampler<float4, 2> envmap;
RT_PROGRAM void envmap_miss()
{
  float theta = atan2f( ray.direction.x, ray.direction.z );
  float phi   = M_PIf * 0.5f -  acosf( ray.direction.y );
  float u     = (theta + M_PIf) * (0.5f * M_1_PIf);
  float v     = 0.5f * ( 1.0f + sin(phi) );
  prd_radiance.result = make_float3( tex2D(envmap, u, v) );
}
  

//
// Terminates and fully attenuates ray after any hit
//
RT_PROGRAM void any_hit_shadow()
{
  // this material is opaque, so it fully attenuates all shadow rays
  prd_shadow.attenuation = make_float3(0);

  rtTerminateRay();
}
  

//
// Phong surface shading with shadows 
//
rtDeclareVariable(float3,   Kd, , );
rtDeclareVariable(float3,   Ka, , );
rtDeclareVariable(float3,   Ks, , );
rtDeclareVariable(float,    phong_exp, , );
rtDeclareVariable(float3,   ambient_light_color, , ); 
rtBuffer<BasicLight>        lights;
rtDeclareVariable(rtObject, top_shadower, , );

RT_PROGRAM void closest_hit_radiance()
{
  float3 world_geo_normal   = normalize( rtTransformNormal( RT_OBJECT_TO_WORLD, geometric_normal ) );
  float3 world_shade_normal = normalize( rtTransformNormal( RT_OBJECT_TO_WORLD, shading_normal ) );
  float3 ffnormal     = faceforward( world_shade_normal, -ray.direction, world_geo_normal );
  float3 color = Ka * ambient_light_color;

  float3 hit_point = ray.origin + t_hit * ray.direction;

  for(int i = 0; i < lights.size(); ++i) {
    BasicLight light = lights[i];
    float3 L = normalize(light.pos - hit_point);
    float nDl = dot( ffnormal, L);

    if( nDl > 0.0f ){
      // cast shadow ray
      PerRayData_shadow shadow_prd;
      shadow_prd.attenuation = make_float3(1.0f);
      float Ldist = length(light.pos - hit_point);
      optix::Ray shadow_ray( hit_point, L, shadow_ray_type, scene_epsilon, Ldist );
      rtTrace(top_shadower, shadow_ray, shadow_prd);
      float3 light_attenuation = shadow_prd.attenuation;

      if( fmaxf(light_attenuation) > 0.0f ){
        float3 Lc = light.color * light_attenuation;
        color += Kd * nDl * Lc;

        float3 H = normalize(L - ray.direction);
        float nDh = dot( ffnormal, H );
        if(nDh > 0)
          color += Ks * Lc * pow(nDh, phong_exp);
      }

    }
  }
  prd_radiance.result = color;
}
  

//
// (UPDATED)
// Phong surface shading with shadows and schlick-approximated fresnel reflections
//
rtDeclareVariable(float3, reflectivity, , );
rtDeclareVariable(float, importance_cutoff, , );
rtDeclareVariable(int, max_depth, , );
rtDeclareVariable(float3, reflectivity_n, , );

RT_PROGRAM void floor_closest_hit_radiance()
{
  float3 world_geo_normal   = normalize( rtTransformNormal( RT_OBJECT_TO_WORLD, geometric_normal ) );
  float3 world_shade_normal = normalize( rtTransformNormal( RT_OBJECT_TO_WORLD, shading_normal ) );
  float3 ffnormal     = faceforward( world_shade_normal, -ray.direction, world_geo_normal );
  float3 color = Ka * ambient_light_color;

  float3 hit_point = ray.origin + t_hit * ray.direction;

  for(int i = 0; i < lights.size(); ++i) {
    BasicLight light = lights[i];
    float3 L = normalize(light.pos - hit_point);
    float nDl = dot( ffnormal, L);

    if( nDl > 0.0f ){
      // cast shadow ray
      PerRayData_shadow shadow_prd;
      shadow_prd.attenuation = make_float3(1.0f);
      float Ldist = length(light.pos - hit_point);
      optix::Ray shadow_ray( hit_point, L, shadow_ray_type, scene_epsilon, Ldist );
      rtTrace(top_shadower, shadow_ray, shadow_prd);
      float3 light_attenuation = shadow_prd.attenuation;

      if( fmaxf(light_attenuation) > 0.0f ){
        float3 Lc = light.color * light_attenuation;
        color += Kd * nDl * Lc;

        float3 H = normalize(L - ray.direction);
        float nDh = dot( ffnormal, H );
        if(nDh > 0)
          color += Ks * Lc * pow(nDh, phong_exp);
      }

    }
  }

  float3 r = schlick(-dot(ffnormal, ray.direction), reflectivity_n);
  float importance = prd_radiance.importance * optix::luminance( r );

  // reflection ray
  if( importance > importance_cutoff && prd_radiance.depth < max_depth) {
    PerRayData_radiance refl_prd;
    refl_prd.importance = importance;
    refl_prd.depth = prd_radiance.depth+1;
    float3 R = reflect( ray.direction, ffnormal );
    optix::Ray refl_ray( hit_point, R, radiance_ray_type, scene_epsilon );
    rtTrace(top_object, refl_ray, refl_prd);
    color += r * refl_prd.result;
  }

  prd_radiance.result = color;
}


//
// Set pixel to solid color upon failure
//
RT_PROGRAM void exception()
{
  output_buffer[launch_index] = make_color( bad_color );
}
