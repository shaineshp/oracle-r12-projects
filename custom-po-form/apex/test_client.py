"""Client behavior tests using macOS JavaScriptCore; no browser or Oracle DB.

Run: python3 custom-po-form/apex/test_client.py
"""
import ctypes
import ctypes.util
from pathlib import Path


def run():
    path = ctypes.util.find_library("JavaScriptCore")
    if not path:
        raise SystemExit("JavaScriptCore unavailable; run these tests on macOS.")
    lib = ctypes.CDLL(path)
    ptr = ctypes.c_void_p
    signatures = {
        "JSGlobalContextCreate": ([ptr], ptr),
        "JSStringCreateWithUTF8CString": ([ctypes.c_char_p], ptr),
        "JSEvaluateScript": ([ptr, ptr, ptr, ptr, ctypes.c_int, ctypes.POINTER(ptr)], ptr),
        "JSValueToStringCopy": ([ptr, ptr, ctypes.POINTER(ptr)], ptr),
        "JSStringGetMaximumUTF8CStringSize": ([ptr], ctypes.c_size_t),
        "JSStringGetUTF8CString": ([ptr, ctypes.c_char_p, ctypes.c_size_t], ctypes.c_size_t),
        "JSStringRelease": ([ptr], None),
        "JSGlobalContextRelease": ([ptr], None),
    }
    for name, (args, result) in signatures.items():
        method = getattr(lib, name)
        method.argtypes, method.restype = args, result
    context = lib.JSGlobalContextCreate(None)

    def evaluate(source):
        script = lib.JSStringCreateWithUTF8CString(source.encode())
        error = ptr()
        value = lib.JSEvaluateScript(context, script, None, None, 1, ctypes.byref(error))
        lib.JSStringRelease(script)
        string = lib.JSValueToStringCopy(context, error.value or value, None)
        size = lib.JSStringGetMaximumUTF8CStringSize(string)
        output = ctypes.create_string_buffer(size)
        lib.JSStringGetUTF8CString(string, output, size)
        lib.JSStringRelease(string)
        text = output.value.decode()
        if error.value:
            raise AssertionError(text)
        return text

    try:
        evaluate(r"""
          class Node {
            constructor() { this.children=[];this.classList={toggle(){}};this.value=''; }
            append(...nodes){this.children.push(...nodes);}
            replaceChildren(...nodes){this.children=nodes;}
            querySelectorAll(){return [];}
            addEventListener(){}
            closest(){return null;}
          }
          const nodes={};
          globalThis.document={createElement:()=>new Node(),getElementById:id=>nodes[id]||(nodes[id]=new Node())};
          globalThis.window={confirm:()=>true};
          globalThis.calls=[];
          globalThis.reply=()=>({ok:true});
          globalThis.apex={jQuery(){},server:{process(name,data){calls.push(data);return Promise.resolve(reply(data));}}};
          function assert(value,message){if(!value)throw new Error(message);}
        """)
        source = Path(__file__).with_name("po-entry.js").read_text()
        marker = "apex.jQuery(init);"
        assert marker in source
        # Instrument only the in-memory test copy; production exports no hooks.
        source = source.replace(marker, "globalThis.hooks={state,headerFields,lineFields,payload,api,save,render};")
        evaluate(source)
        evaluate(r"""
          assert(hooks.headerFields.length===8 && hooks.lineFields.length===12,'20 fields');
          const s=hooks.state;
          s.header=Object.fromEntries(hooks.headerFields.map(([key])=>[key,key==='currency_code'?'INR':1]));
          const line=Object.fromEntries(hooks.lineFields.map(([key])=>[key,1]));
          Object.assign(line,{item_id:null,item_description:'Materials',unit_of_measure:'Each',need_by_date:'2030-01-01',destination_type_code:'EXPENSE',quantity:2,unit_price:10});
          s.lines=[line];
          assert(hooks.payload().lines[0].item_id===null,'Description-based line allowed');
          line.quantity=-1;
          let rejected=false;try{hooks.payload();}catch(e){rejected=true;}
          assert(rejected,'Negative quantity must fail before AJAX');line.quantity=2;
          line.unit_price=Infinity;rejected=false;try{hooks.payload();}catch(e){rejected=true;}
          assert(rejected,'Infinite price must fail');line.unit_price=10;
          s.lines.push({...line,line_num:99});hooks.render();
          assert(s.lines[0].line_num===1&&s.lines[1].line_num===2,'Contiguous line numbers');
          s.lines.pop();
          globalThis.done='pending';
          (async()=>{
            const body={text:'🙂'.repeat(6500)};
            await hooks.api('TEST',{},body);
            assert(JSON.stringify(body)===calls[0].f01.join(''),'Unicode payload roundtrip');
            assert(calls[0].f01.length>1,'Large payload chunked');
            calls.length=0;
            reply=data=>{
              if(data.x01==='LIST')return {ok:true,rows:[]};
              const payload=JSON.parse(data.f01.join(''));
              if(data.x01==='POST')assert(payload.draft_id===77 && payload.revision===1,'Post uses persisted ID and revision');
              return {ok:true,header:[{...s.header,draft_id:77,apex_revision:1,status:data.x01==='POST'?'SUBMITTED':'DRAFT',request_id:data.x01==='POST'?123:null}],lines:[{...line}],errors:[],purchase_order:[],request:[]};
            };
            await hooks.save(true);
            assert(calls.map(call=>call.x01).join(',')==='SAVE,POST,LIST','Save must precede post');
            assert(s.status==='SUBMITTED'&&!s.dirty,'Posted state is read-only and clean');
            globalThis.done='PASS';
          })().catch(error=>{globalThis.done='FAIL: '+error.message;});
        """)
        result = evaluate("globalThis.done")
        for _ in range(10):
            if result != "pending":
                break
            result = evaluate("globalThis.done")
        assert result == "PASS", result
        print("PASS: 20 fields, optional item, quantity/price validation, line numbering,")
        print("Unicode chunking, durable draft before posting, and submitted client state.")
    finally:
        lib.JSGlobalContextRelease(context)


if __name__ == "__main__":
    run()
