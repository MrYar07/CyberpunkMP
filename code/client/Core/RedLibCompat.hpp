#pragma once

// The RedLib calls this client was written against, on top of the RedLib that supports patch 2.5
// (Codeware 1.21.1's lib/Red). That release dropped Detail::CallFunctionWithArgs without a frame
// and moved GetFunction out of Detail; these forward to the replacements so the call sites keep
// their shape.
namespace Red::Detail
{
template<typename... Args>
inline bool CallFunctionWithArgs(CBaseFunction* aFunc, IScriptable* aContext, Args&&... aArgs)
{
    return CallFunctionWithArgs(nullptr, aFunc, aContext, std::forward<Args>(aArgs)...);
}

template<typename C, typename... Args>
inline bool CallFunctionWithArgs(CBaseFunction* aFunc, const Handle<C>& aContext, Args&&... aArgs)
{
    return CallFunctionWithArgs(nullptr, aFunc, static_cast<IScriptable*>(aContext.instance), std::forward<Args>(aArgs)...);
}

inline CBaseFunction* GetFunction(CClass* aType, CName aName)
{
    return Red::GetFunction(aType, aName);
}
} // namespace Red::Detail
