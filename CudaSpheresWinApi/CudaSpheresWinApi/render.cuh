#include "global.cuh"

__device__ __host__ unsigned int compute_int_color(const float3& v)
{
	unsigned int color = unsigned int(v.z * 255);
	color |= unsigned int(v.y * 255) << 8;
	color |= unsigned int(v.x * 255) << 16;
	return color;
}

__device__ __host__ float3 phong_light(const light& lights, const scene_objects& sphere, int i, float3 N, float3 V)
{
	//int i = hit.index;
	//float3 N = normalize(hit.normal);
	//float3 V = normalize(hit.v);

	float ka = sphere.ka[i];
	float kd = sphere.kd[i];
	float ks = sphere.ks[i];
	int alpha = sphere.alpha[i];

	float3 sphereColor = make_float3(sphere.color.r[i], sphere.color.g[i], sphere.color.b[i]);
	float3 difuseColor = make_float3(0, 0, 0);
	float3 specularColor = make_float3(0, 0, 0);
	float3 pos = make_float3(sphere.primitives.pos.x[i], sphere.primitives.pos.y[i], sphere.primitives.pos.z[i]);

	for (int j = 0; j < LIGHT_COUNT; ++j)
	{
		float3 lightPosition = make_float3(lights.pos.x[j], lights.pos.y[j], lights.pos.z[j]);
		float3 L = normalize(lightPosition - pos);
		difuseColor = difuseColor + dot(L, N) * make_float3(lights.id.r[j], lights.id.g[j], lights.id.b[j]);

		float3 R = normalize(2.0f * dot(L, N) * N - L);
		float product = max(0.0f, dot(R, V));
		if (product > 0.0f)
		{
			product = fastPow(product, alpha);
		}

		specularColor = specularColor + product * make_float3(lights.is.r[j], lights.is.g[j], lights.is.b[j]);
	}

	float3 I = ka * make_float3(sphere.color.r[i], sphere.color.g[i], sphere.color.b[i]) + kd * difuseColor + ks * specularColor;
	I.x = clamp(I.x, .0f, 1.0f);
	I.y = clamp(I.y, .0f, 1.0f);
	I.z = clamp(I.z, .0f, 1.0f);

	return I;
}


__device__ float3 default_color(const ray& r)
{
	float3 unit_direction = normalize(r.direction);
	auto t = 0.5 * (unit_direction.y + 1.0);
	return (1.0 - t) * make_float3(1, 1, 1) + t * make_float3(0.5f, 0.7f, 1.0f);
}

// __device__ __host__ float3 ray_color(const ray& r, const spheres& sphere, const light& lights) {
// 	hit_record rec;
// 	if (sphere.hit_anything(r, 0, 1000, rec))  // 1000 is infinity
// 	{
// 		return phong_light(lights, sphere, rec);
// 	}
// 	return default_color(r);
// }

__device__ float_pair range_case_left_empty(const float_pair& range_l, const float_pair& range_r, int operation)
{
	switch (operation)
	{
	case 0:
		return range_l;
	break;
	case 1:
		return range_r;
	break;
	case 2:
		return range_l;
	break;
	case 3:
		return range_r;
	break;
	default:
		return range_l;
	break;
	}
}


// isLeft - out parameter
// if true, then we should consider left sphere with color, normal etc.
__device__ inline float_pair evaluate_range(float_pair& range_l, float_pair& range_r, int operation, bool& isLeft, bool& isRight)
{
	if (range_l.first == -1)
	{
		isLeft = false;
		isRight = true;
		return range_case_left_empty(range_l, range_r, operation);
	}
	else if (range_r.first == -1)
	{
		isLeft = true;
		isRight = false;
		return range_case_left_empty(range_r, range_l, operation);
	}

	bool realLeft = true;
	bool realRight = true;
	if (range_l.first > range_r.first)
	{
		auto temp = range_l;
		range_l = range_r;
		range_r = temp;
		realLeft = false;
		realRight = false;
	}
	// now we have
	// range_l.left (range_l.right and range_r.left or switched) (range_r.right or range_l.right or switched)

	switch (operation)
	{
		// intersection
		case 0:
		{
			if (range_l.second < range_r.first)
			{
				isLeft = realLeft; // whatever
				isRight = realRight; // whatever
				return make_pair(-1, -1); // no intersection
			}
			isLeft = !realLeft;
			isRight = range_l.second < range_r.second ? !realRight : realRight;
			return make_pair(range_r.first, min(range_l.second, range_r.second));
		}

		break;

		// sum
		case 1:
		{
			isLeft = realLeft;
			isRight = range_l.second > range_r.second ? !realRight : realRight;
			return make_pair(range_l.first, max(range_l.second, range_r.second));
		}
		break;

		// left \ right
		case 2:
		{
			if (range_l.first <= range_r.first)
			{
				isLeft = realLeft; // whatever
				isRight = realRight; // whatever
				return make_pair(-1, -1); //no intersection
			}
			isLeft = realLeft;
			isRight = range_l.second < range_r.second ? !realRight : realRight;
			return make_pair(range_l.first, min(range_l.second, range_r.first));
		}
		break;

		// right \ left
		case 3:
		{
			if (range_r.second <= range_l.second)
			{
				isLeft = realLeft; // whatever
				isRight = realRight; // whatever
				return make_pair(-1, -1);
			}
			isLeft = range_l.second > range_r.first ? realLeft : !realLeft;
			isRight = realRight;
			return make_pair(max(range_l.second, range_r.first), range_r.second);
		}
		break;

		default:
		{
			isLeft = realLeft; // whatever
			isRight = realRight; // whatever
			return make_pair(-1, -1);
		}
		break;
	}
}

__global__ void render(unsigned int* mem_ptr, camera cam, light lights, csg_scene scene, int maxX, int maxY)
{
	int x = blockIdx.x;//threadIdx.x + blockIdx.x * blockDim.x;
	int y = blockIdx.y;//threadIdx.y + blockIdx.y * blockDim.y;
	if (x >= maxX || y >= maxY)
		return;

	scene.levels = 2;
	scene.nodesCount = 3;
	scene.count = 2;

	int levels = 2;// scene.levels;

	ray r = cam.get_ray(float(x) / (maxX - 1), float(maxY - y) / (maxY - 1));

	hit_record rec;
	if (!scene.bounding.hit(0, r, 0, 1000, rec))
	{
		mem_ptr[y * maxX + x] = compute_int_color(default_color(r));
		return;
	}


	int smallPow = pow(2, levels - 1);
	int bigPow = pow(2, levels);

	extern __shared__ float csg_ranges[];

	float* left_ranges_tree = (float*)csg_ranges;
	float* right_ranges_tree = (float*)&csg_ranges[bigPow];
	int* sph_indices = (int*)&csg_ranges[2 * bigPow - 1];
	float3* normals = (float3*)&csg_ranges[3 * bigPow - 2];
	int cntr = 0;
	for (int i = smallPow - 1; i < bigPow - 1; i += 32)
	{
		if (i + threadIdx.x < bigPow - 1)
		{
			int index = scene.csg[i + threadIdx.x];
			if (scene.objects.primitives.hit(index, r, 0, 1000, rec))
			{
				left_ranges_tree[i] = rec.t1;
				right_ranges_tree[i] = rec.t2;
				sph_indices[i] = index;
				normals[index] = rec.normal;
			}
			else
			{
				left_ranges_tree[i] = -1;
				right_ranges_tree[i] = -1;
			}
		}
		cntr++;
		while (cntr < 32) {}
		cntr = 0;
	}
	cntr = 0;
	for (int i = levels - 2; i >= 0; --i)
	{
		for (int j = pow(2, i) - 1; i < pow(2, i + 1) - 1; i += 32)
		{
			if (j + threadIdx.x < pow(2, i + 1) - 2)
			{
				int left = 2 * j + 1;
				int right = 2 * j + 2;

				if (left_ranges_tree[left] != -1 || left_ranges_tree[right] != -1)
				{
					bool leftSph, rightSph;
					float_pair range = evaluate_range(
						make_pair(left_ranges_tree[left], right_ranges_tree[left]),
						make_pair(left_ranges_tree[right], right_ranges_tree[right]),
						scene.csg[j], leftSph, rightSph);

					if (range.first > range.second)
					{
						auto temp = range.first;
						range.first = range.second;
						range.second = temp;

						bool s_temp = leftSph;
						leftSph = rightSph;
						rightSph = s_temp;
					}

					left_ranges_tree[j] = range.first;
					right_ranges_tree[j] = range.second;
					sph_indices[j] = leftSph ? sph_indices[left] : sph_indices[right];
				}
				else
				{
					left_ranges_tree[j] = -1;
					right_ranges_tree[j] = -1;
				}
			}
			cntr++;
			while (cntr < 32) {}
			cntr = 0;
		}
	}

	float3 c = phong_light(lights, scene.objects, sph_indices[0], normals[sph_indices[0]], -1 * r.direction); //ray_color(r, sphere, lights);
	mem_ptr[y * maxX + x] = compute_int_color(c);
}

