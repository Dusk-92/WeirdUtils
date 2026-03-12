
void __thiscall
findInterpolationIndices
          (SceneObject *this,uint searchValue,uint trackIndex,AnimationData *animationData,
          uint *outputIndices)

{
  uint search_distance;
  uint search_delta;
  uint min_index;
  uint *timestamp_ptr;
  uint start_index;
  int current_timestamp;
  ushort time_index;
  uint timestamps_addr;
  
  if (animationData->track_count_flag == 0) {
    min_index = 0;
    start_index = animationData->keyframe_count - 1;
  }
  else {
    start_index = *(uint *)(animationData->keyframe_ranges_ptr + 4 + trackIndex * 8);
    min_index = *(uint *)(animationData->keyframe_ranges_ptr + trackIndex * 8);
  }
  if (start_index <= min_index) {
    *outputIndices = min_index;
    outputIndices[1] = min_index;
    outputIndices[2] = 0;
    return;
  }
  time_index = *(ushort *)((int)&animationData->interpolationModeAndTimeIndex + 2);
  if (time_index != 0xffff) {
    searchValue = *(uint *)(this->search_data_count + (uint)time_index * 4);
  }
  timestamps_addr = animationData->timestamps_ptr;
  search_delta = *outputIndices;
  search_distance = searchValue - *(int *)(timestamps_addr + search_delta * 4);
  if (search_distance < 500) {
    if (search_delta < start_index) {
      timestamp_ptr = (uint *)(timestamps_addr + 4 + search_delta * 4);
      do {
        if (searchValue < *timestamp_ptr) break;
        search_delta = search_delta + 1;
        timestamp_ptr = timestamp_ptr + 1;
      } while (search_delta < start_index);
    }
  }
  else if (search_distance < 0xfffffe0c) {
    if (searchValue - *(int *)(timestamps_addr + min_index * 4) < 500) {
      timestamp_ptr = (uint *)(timestamps_addr + 4 + min_index * 4);
      do {
        search_delta = min_index;
        if (searchValue < *timestamp_ptr) break;
        min_index = min_index + 1;
        timestamp_ptr = timestamp_ptr + 1;
        search_delta = min_index;
      } while (min_index < start_index);
    }
    else {
      do {
        search_delta = start_index + min_index >> 1;
        if (searchValue < *(uint *)(timestamps_addr + search_delta * 4)) {
          start_index = search_delta - 1;
        }
        else {
          min_index = search_delta + 1;
          if (searchValue < *(uint *)(timestamps_addr + 4 + search_delta * 4)) break;
        }
        search_delta = min_index;
      } while (min_index < start_index);
    }
  }
  else if (min_index < search_delta) {
    timestamp_ptr = (uint *)(timestamps_addr + search_delta * 4);
    do {
      if (*timestamp_ptr <= searchValue) break;
      search_delta = search_delta - 1;
      timestamp_ptr = timestamp_ptr + -1;
    } while (min_index < search_delta);
  }
  start_index = search_delta + 1;
  if (animationData->keyframe_count <= start_index) {
    outputIndices[1] = search_delta;
    *outputIndices = search_delta;
    outputIndices[2] = 0;
    return;
  }
  *outputIndices = search_delta;
  outputIndices[1] = start_index;
  current_timestamp = *(int *)(animationData->timestamps_ptr + search_delta * 4);
  outputIndices[2] =
       (uint)((float)(searchValue - current_timestamp) /
             (float)(*(int *)(animationData->timestamps_ptr + start_index * 4) - current_timestamp))
  ;
  return;
}

