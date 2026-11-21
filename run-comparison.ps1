param(
    [string]$RepoRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'work'),
    [string]$Compiler = (Join-Path $PSScriptRoot 'llvm-mingw-20261117-ucrt-x86_64/bin/clang++.exe'),
    [string]$OutputDirectory = $PSScriptRoot,
    [switch]$AISOnly
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null

function Read-Source($repo, $revision, $name) {
    $rel = "indra/newview/$name"
    if ($revision) {
        $source = git -C $repo show "${revision}:$rel"
        if ($LASTEXITCODE -ne 0) { throw "git show failed for $repo $revision $rel" }
        return $source -join "`n"
    }
    return Get-Content -Raw -LiteralPath (Join-Path $repo $rel)
}

$preamble = @'
#include <cassert>
#include <functional>
#include <iostream>
#include <set>
#include <string>
#include <utility>
#include <vector>

struct LLUUID {
    int value = 0;
    static const LLUUID null;
    bool notNull() const { return value != 0; }
    std::string asString() const { return std::to_string(value); }
    bool operator<(const LLUUID& rhs) const { return value < rhs.value; }
    bool operator==(const LLUUID& rhs) const { return value == rhs.value; }
};
const LLUUID LLUUID::null{};
std::ostream& operator<<(std::ostream& stream, const LLUUID& id) { return stream << id.value; }
struct LLSD {};
namespace LLCore {
    struct HttpRequest { using ptr_t = int; };
    struct HttpOptions { using ptr_t = int; };
    struct HttpHeaders { using ptr_t = int; };
}
namespace LLCoreHttpUtil {
    struct HttpCoroutineAdapter {
        using ptr_t = HttpCoroutineAdapter*;
        LLSD getAndSuspend(int, const std::string&, int, int) { return {}; }
    };
}
namespace boost { using std::bind; }
using namespace std::placeholders;
struct LogCounter {
    int warnings = 0;
    int debug = 0;
    bool debug_enabled = false;
};
LogCounter logs;
struct Sink {
    template<class T> Sink& operator<<(const T&) { return *this; }
};
#define LL_WARNS(...) (++logs.warnings, Sink{})
#define LL_DEBUGS(...) if (logs.debug_enabled) (++logs.debug, Sink{})
#define LL_ENDL 0
struct LLCoprocedureManager {
    using CoProcedure_t = std::function<void(LLCoreHttpUtil::HttpCoroutineAdapter::ptr_t&, const LLUUID&)>;
};
class AISAPI {
public:
    enum ITEM_TYPE { INVENTORY, LIBRARY };
    enum COMMAND_TYPE { FETCHITEM };
    using completion_t = std::function<void(const LLUUID&)>;
    using invokationFn_t = std::function<LLSD(LLCoreHttpUtil::HttpCoroutineAdapter::ptr_t, int,
                                             std::string, LLSD, int, int)>;
    static inline std::string inventory = "inventory-a";
    static inline std::string library = "library-a";
    static inline std::vector<LLCoprocedureManager::CoProcedure_t> requests;
    static inline std::set<LLUUID> accepted;
    static inline bool failed = false;
    static std::string getInvCap() { return inventory; }
    static std::string getLibCap() { return library; }
    static void InvokeAISCommandCoro(LLCoreHttpUtil::HttpCoroutineAdapter::ptr_t adapter,
                                     invokationFn_t invoke, std::string url, LLUUID id, LLSD body,
                                     completion_t callback, COMMAND_TYPE) {
        invoke(adapter, 0, url, body, 0, 0);
        if (!failed) accepted.insert(id);
        if (callback) callback(failed ? LLUUID{} : id);
    }
    static void EnqueueAISCommand(const std::string&, LLCoprocedureManager::CoProcedure_t proc) {
        requests.push_back(std::move(proc));
    }
    FETCH_DECLARATION
};
using U32 = unsigned;
using S32 = int;
struct LLInventoryObserver { enum { LABEL = 1, ADD = 2 }; };
struct Permissions { LLUUID getOwner() const { return LLUUID{1}; } };
struct LLViewerInventoryItem {
    bool isFinished() const { return true; }
    Permissions getPermissions() const { return {}; }
    const char* getName() const { return "synthetic item"; }
};
struct LLViewerInventoryCategory {
    const char* getName() const { return "synthetic folder"; }
};
struct LLInventoryModel {
    bool mIsNotifyObservers = false;
    U32 mModifyMaskBacklog = 0, mModifyMask = 0;
    std::set<LLUUID> mChangedItemIDsBacklog, mChangedItemIDs, mAddedItemIDsBacklog, mAddedItemIDs;
    LLViewerInventoryItem* getItem(const LLUUID& id) {
        static LLViewerInventoryItem item;
        return id.value % 2 == 0 ? &item : nullptr;
    }
    LLViewerInventoryCategory* getCategory(const LLUUID&) {
        static LLViewerInventoryCategory category;
        return &category;
    }
    void addChangedMask(U32 mask, const LLUUID& referent);
    void addChangedMaskForLinks(const LLUUID&, U32) {}
} observer_model;
struct FetchInventory {
    LLViewerInventoryItem* getItem(const LLUUID& id) {
        return AISAPI::accepted.count(id) ? observer_model.getItem(LLUUID{2}) : nullptr;
    }
} gInventory;
struct { LLUUID getID() const { return LLUUID{1}; } } gAgent;
void update_marketplace_category(const LLUUID&, bool) {}
enum { FT_DEFAULT, FT_FORCED };
struct FetchQueueInfo { LLUUID mUUID; int mFetchType; };
S32 mFetchCount = 0;
std::set<LLUUID> mForceFetchSet;
void ais_simple_item_callback(const LLUUID&) { --mFetchCount; }
'@

$checks = @'
int main()
{
    using A = AISAPI;
    int peak = 0;
    size_t submissions = 0;
    for (int group = 0; group < 200; ++group)
    {
        for (int caller = 0; caller < 3; ++caller)
        {
            for (int offset = 0; offset < 6; ++offset)
            {
                dispatch({LLUUID{group * 6 + offset + 1}, FT_DEFAULT});
                if (mFetchCount > peak) peak = mFetchCount;
                assert(mFetchCount <= 19);
            }
        }
        assert(static_cast<size_t>(mFetchCount) == A::requests.size());
        submissions += A::requests.size();
        drain();
        assert(mFetchCount == 0);
    }
    assert(A::accepted.size() == 1200);
    assert(submissions == (patched ? 1200 : 3600));
    assert(peak == (patched ? 6 : 18));

    // A false admission must not leak a slot. Force still refreshes a complete record.
    dispatch({LLUUID{1}, FT_DEFAULT});
    assert(A::requests.empty() && mFetchCount == 0);
    mForceFetchSet.insert(LLUUID{1});
    dispatch({LLUUID{1}, FT_FORCED});
    assert(A::requests.size() == 1 && mForceFetchSet.empty());
    drain();
    assert(mFetchCount == 0);
    A::inventory.clear();
    dispatch({LLUUID{1201}, FT_DEFAULT});
    assert(A::requests.empty() && mFetchCount == 0);
    A::inventory = "inventory-a";
    A::failed = true;
    dispatch({LLUUID{1201}, FT_DEFAULT});
    drain();
    assert(mFetchCount == 0 && A::accepted.count(LLUUID{1201}) == 0);
    A::failed = false;
    dispatch({LLUUID{1201}, FT_DEFAULT});
    drain();
    assert(mFetchCount == 0 && A::accepted.count(LLUUID{1201}) == 1);

    logs = {};
    observer_model.mIsNotifyObservers = true;
    for (int index = 1; index <= 27244; ++index)
    {
        observer_model.addChangedMask(LLInventoryObserver::ADD, LLUUID{index});
    }
    assert(observer_model.mModifyMask == 0 && observer_model.mChangedItemIDs.empty());
    assert(observer_model.mModifyMaskBacklog == LLInventoryObserver::ADD);
    assert(observer_model.mChangedItemIDsBacklog.size() == 27244);
    assert(observer_model.mAddedItemIDsBacklog == observer_model.mChangedItemIDsBacklog);
    assert(logs.warnings == (observerPatched ? 0 : 54488) && logs.debug == 0);
    int warning_count = logs.warnings;
    logs.debug_enabled = true;
    observer_model.addChangedMask(LLInventoryObserver::ADD, LLUUID{1});
    assert(logs.debug == (observerPatched ? 1 : 0));
    assert(observer_model.mChangedItemIDsBacklog.size() == 27244);
    observer_model.mIsNotifyObservers = false;
    observer_model.addChangedMask(LLInventoryObserver::ADD, LLUUID{30000});
    assert(observer_model.mChangedItemIDs.size() == 1);
    assert(observer_model.mAddedItemIDs.size() == 1);
    std::cout << submissions << ',' << peak << ',' << 1200 << ','
              << warning_count << ',' << observer_model.mChangedItemIDsBacklog.size() << '\n';
}
'@

$rows = @()
foreach ($viewer in 'secondlife-viewer','firestorm-viewer') {
    $repo = Join-Path $RepoRoot $viewer
    foreach ($mode in 'upstream','local-candidate') {
        $isPatched = $mode -eq 'local-candidate'
        $revision = if (!$isPatched) { 'fix/ais-coalesce-item-fetches~1' } elseif ($AISOnly) { 'fix/ais-coalesce-item-fetches' }
        $ais = Read-Source $repo $revision 'llaisapi.cpp'
        $background = Read-Source $repo $revision 'llinventorymodelbackgroundfetch.cpp'
        $observer = Read-Source $repo $revision 'llinventorymodel.cpp'
        $fetch = [regex]::Match($ais, '(?ms)^(?:bool|void) AISAPI::FetchItem\(.*?^\}').Value
        $dispatch = [regex]::Match($background, '(?ms)^        LLViewerInventoryItem\* itemp\(gInventory\.getItem\(fetch_info\.mUUID\)\);.*?^    \}\r?\n\r?\n    if \(fetch_info\.mFetchType == FT_FORCED\)\r?\n    \{\r?\n        mForceFetchSet\.erase\(fetch_info\.mUUID\);\r?\n    \}').Value
        $notify = [regex]::Match($observer, '(?ms)^void LLInventoryModel::addChangedMask\(.*?^\}').Value
        if (!$fetch -or !$dispatch -or !$notify) { throw "Viewer source extraction failed for $viewer $mode" }

        $decl = [regex]::Match($fetch, '(?m)^(bool|void) AISAPI::(FetchItem\(.*\))').Groups
        $source = $preamble.Replace('FETCH_DECLARATION', "static $($decl[1].Value) $($decl[2].Value);")
        $observerPatched = $isPatched -and !$AISOnly
        $source += "`nconstexpr bool patched = $($isPatched.ToString().ToLower());`n"
        $source += "constexpr bool observerPatched = $($observerPatched.ToString().ToLower());`n$fetch`n$notify`n"
        $source += "void dispatch(const FetchQueueInfo& fetch_info)`n{`n    {`n$dispatch`n}`n"
        $source += @'
void drain()
{
    LLCoreHttpUtil::HttpCoroutineAdapter adapter;
    auto ptr = &adapter;
    for (auto& req : AISAPI::requests) req(ptr, {});
    AISAPI::requests.clear();
}
'@
        $source += "`n$checks"
        $prefix = Join-Path $OutputDirectory "$viewer-$mode"
        $source | Set-Content -LiteralPath "$prefix.cpp" -Encoding utf8
        & $compiler -std=c++17 -Wall -Wextra -Werror -static "$prefix.cpp" -o "$prefix.exe"
        if ($LASTEXITCODE -ne 0) { throw "Compile failed for $viewer $mode" }
        $data = & "$prefix.exe"
        if ($LASTEXITCODE -ne 0) { throw "Regression failed for $viewer $mode" }
        $rows += "$viewer,$mode,$data"
    }
}
@('viewer,mode,ais_gets,peak_active,unique_items,default_observer_warnings,backlogged_ids') + $rows |
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'comparison.csv') -Encoding utf8
$rows
