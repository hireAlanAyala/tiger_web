
# prefetch db is sidecar talking to a secondary storage interface
prefetch db.query is pure ts for db reads only, instead of calling to zig.
avoids a lot of latency in scenarios like this:

prefetch                                                                                                                                                                                       
const id = await db.query('get user id')                                                                                                                                                       
const user  = await db.query('get user')                                                                                                                                                       

Gain: 17k -> 25k


# new
  Currently with the QUERY sub-protocol, the flow is:                                                                                                                                          
  slot gets request → send CALL → wait → TS queries via QUERY → Zig reads SQLite → sends QR → wait → TS finishes → RESULT → execute → encode → send
                                                                                                                                                                                               
  With native prefetch:                                                                                                                                                                        
  slot gets request → Zig reads SQLite → send CALL (with data) → wait → TS runs (no await) → RESULT → execute → encode → send


● Sidecar orchestration v2                                                                                                                                                                     
                                         
  Principles                                                                                                                                                                                   
                                                                                                                                                                                               
  - Heavy sidecar, thin framework. TS owns all user logic (route, prefetch declaration, handle, render). Zig owns transport, SQLite, safety.                                                   
  - Pipeline to fill every gap. While Zig reads SQLite for request A, TS processes RT1 for request B. Neither side idles.
  - Writes serialize, everything else flows. Reads are concurrent (SQLite WAL). Only db.execute() takes the lock.                                                                              
  - No await in prefetch. Prefetch declares queries, doesn't execute them. Pushes users toward JOINs and good REST design.                                                                     
  - 1 process, fully saturated. Pipelining eliminates the need for multiple TS processes. One process, one V8 heap, ~30MB.                                                                     
                                                                                                                                                                                               
  Protocol: 2 RTs, 4 frames, pipelined                                                                                                                                                         
                                                                                                                                                                                               
  RT1: CALL  → { HTTP method, path, body }                                                                                                                                                     
       RESULT ← { operation, id, params, queries: [{sql, params}] }
                                                                                                                                                                                               
       Zig executes prefetch SQL (concurrent across slots)                                                                                                                                     
                                                                                                                                                                                               
  RT2: CALL  → { prefetched rows }                                                                                                                                                             
       RESULT ← { status, session_action, writes: [{sql, params}], html }
                                                                                                                                                                                               
       Zig executes writes (serial), sends HTTP response
                                                                                                                                                                                               
  Pipeline across requests (1 TS process)                                                                                                                                                      
   
  time →                                                                                                                                                                                       
                                         
  Zig:  [send RT1-A] [recv RT1-A, exec SQL-A, send RT2-A] [recv RT2-A, write, send resp-A]                                                                                                     
  TS:   [route+prefetch A]  [route+prefetch B]  [handle+render A]  [route+prefetch C]  [handle+render B]
  Zig:                [send RT1-B] [recv RT1-B, exec SQL-B, send RT2-B] [recv RT2-B, write, send resp-B]                                                                                       
                                         
  TS alternates between RT1 (route + prefetch declaration) and RT2 (handle + render) for different requests. While Zig does SQLite for A, TS does RT1 for B. While Zig does SQLite for B, TS   
  does RT2 for A. Zero idle time on either side.
                                                                                                                                                                                               
  User space                             

  // [route] .list_products
  // match GET /products                                                                                                                                                                       
  // query cursor
  export function route(req) {                                                                                                                                                                 
    if (req.params.q) return null;       
    return { operation: "list_products", cursor: req.params.cursor };                                                                                                                          
  }                                                                                                                                                                                            
                                                                                                                                                                                               
  // [prefetch] .list_products                                                                                                                                                                 
  export function prefetch(msg) {        
    return { sql: "SELECT ... WHERE id > ? ORDER BY id LIMIT 18", params: [msg.cursor] };
  }                                                                                                                                                                                            
   
  // [handle] .list_products                                                                                                                                                                   
  export function handle(ctx) {          
    // ctx.rows = prefetched data from framework
    return "ok";
  }

  // [render] .list_products                                                                                                                                                                   
  export function render(ctx) {
    return ctx.rows.map(p => `<div>${p.name}</div>`).join("");                                                                                                                                 
  }                                      

  Four functions. No async. No db object. No await. Prefetch is a pure function returning {sql, params}. Handle and render receive rows from the framework.                                    
   
  Framework responsibilities                                                                                                                                                                   
                                         
  - HTTP parse + route dispatch (native, comptime table validates TS route)                                                                                                                    
  - Execute prefetch SQL (concurrent reads, WAL snapshots)
  - Serialize prefetched rows into CALL frame                                                                                                                                                  
  - Execute writes from RESULT (serial, handle_lock)                                                                                                                                           
  - WAL append                                                                                                                                                                                 
  - Response encoding + send                                                                                                                                                                   
                                                                                                                                                                                               
  What this achieves                                                                                                                                                                           
  
  - 1 process: ~33-42K req/s (vs 17K current, vs 49K Fastify)                                                                                                                                  
  - 2 processes: ~50-65K req/s (matches or exceeds Fastify)
  - Memory: 1 Zig (~17MB) + 1 Node (~30MB) = ~47MB total vs Fastify ~50MB                                                                                                                      
  - Determinism: TB-correct. Zig owns all SQLite. Reads snapshot before writes. Writes serialize.                                                                                              
