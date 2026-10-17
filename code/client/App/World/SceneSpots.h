#pragma once

#include <RED4ext/Scripting/Natives/Generated/world/StreamingSector.hpp>

// Campaign co-op, stage 4c: free places for other players' characters during a scene.
// World AI spots (worldAISpotNode -> AIActionSpot -> .workspot) whose workspot is one of the
// generic sit/stand poses from SceneSpotsData.inl, found in a loaded streaming sector.
namespace SceneSpots
{
// Spots within aRadius of aCenter, ';'-separated "node:x:y:z:forwardX:forwardY:kind"
// (node = global node id, i.e. its NodeRef; kind 1 = sit, 2 = stand).
Red::CString Find(const Red::Handle<Red::world::StreamingSector>& aSector, const Red::Vector4& aCenter, float aRadius);
}
