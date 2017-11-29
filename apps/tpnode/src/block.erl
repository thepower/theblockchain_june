-module(block).
-export([blkid/1]).
-export([mkblock/1,binarizetx/1,extract/1,outward_mk/2]).
-export([verify/1,outward_verify/1,sign/2,sign/3]).
-export([test/0]).
-export([pack_sign_ed/1,unpack_sign_ed/1,splitsig/1,unpacksig/1]).
-export([checksigs/2,checksig/2]).
-export([signhash/3]).

   

checksig(BlockHash, SrcSig) ->
    HSig=unpacksig(SrcSig),
    #{binextra:=BExt,extra:=Xtra,signature:=Sig}=US=block:unpacksig(HSig),
    PubKey=proplists:get_value(pubkey,Xtra),
    Msg=crypto:hash(sha256,<<BExt/binary,BlockHash/binary>>),
    case secp256k1:secp256k1_ecdsa_verify(Msg, Sig, PubKey) of
        correct ->
            {true, US};
        _ ->
            false
    end.

checksigs(BlockHash, Sigs) ->
    lists:foldl(
      fun(SrcSig,{Succ,Fail}) ->
              case checksig(BlockHash, SrcSig) of
                  {true, US} ->
                      {[US|Succ], Fail};
                  false ->
                      {Succ, Fail+1}
              end
      end, {[],0}, Sigs).

outward_verify(#{ header:=#{parent:=Parent, height:=H}=Header, 
          hash:=HdrHash, 
          sign:=Sigs
        }=Blk) ->
    try
        Txs=maps:get(txs,Blk,[]),
        Txp=maps:get(tx_proof,Blk,[]),
        BTxs=binarizetx(Txs),

        TxRoot=maps:get(txroot,Header,undefined),
        BalsRoot=maps:get(balroot,Header,undefined),
        SettingsRoot=maps:get(setroot,Header,undefined),

        BHeader=lists:foldl(
                  fun({_,undefined},ABHhr) ->
                          ABHhr;
                     ({_N,Root},ABHhr) ->
                          <<ABHhr/binary,
                            Root/binary
                          >>
                  end,
                  <<H:64/integer, %8
                    Parent/binary
                  >>,
                  [{txroot,TxRoot},
                   {balroot,BalsRoot},
                   {setroot,SettingsRoot}
                  ]
                 ),
        Hash=crypto:hash(sha256,BHeader),
        if Hash =/= HdrHash -> throw(false); true -> ok end,
        TxFail=lists:foldl(
                 fun(_,true) -> 
                         true;
                    ({TxID,TxBin},false) ->
                         Proof=proplists:get_value(TxID,Txp),
                         Res=gb_merkle_trees:verify_merkle_proof(TxID,
                                                                 TxBin,
                                                                 TxRoot,
                                                                 Proof),
                         Res=/=ok
                 end, false, BTxs),
        if TxFail -> throw(false); true -> ok end,

        {true, checksigs(Hash, Sigs)}

    catch throw:false ->
              false
    end.

verify(#{ header:=#{parent:=Parent, height:=H}, 
          hash:=HdrHash, 
          sign:=Sigs
        }=Blk) ->

    Txs=maps:get(txs,Blk,[]),
    Bals=maps:get(bals,Blk,#{}),
    Settings=maps:get(settings,Blk,[]),

    BTxs=binarizetx(Txs),
    TxMT=gb_merkle_trees:from_list(BTxs),
    BalsBin=bals2bin(Bals),
    BalsMT=gb_merkle_trees:from_list(BalsBin),
    BSettings=binarize_settings(Settings),
    SettingsMT=gb_merkle_trees:from_list(BSettings),

    TxRoot=gb_merkle_trees:root_hash(TxMT),
    BalsRoot=gb_merkle_trees:root_hash(BalsMT),
    SettingsRoot=gb_merkle_trees:root_hash(SettingsMT),

    BHeader=lists:foldl(
              fun({_,undefined},ABHhr) ->
                      ABHhr;
                 ({_N,Root},ABHhr) ->
                      <<ABHhr/binary,
                        Root/binary
                      >>
              end,
              <<H:64/integer, %8
                Parent/binary
              >>,
              [{txroot,TxRoot},
               {balroot,BalsRoot},
               {setroot,SettingsRoot}
              ]
             ),

    Hash=crypto:hash(sha256,BHeader),
    if Hash =/= HdrHash ->
           false;
       true ->
           {true, checksigs(Hash, Sigs)}
    end.

splitsig(<<255,SLen:8/integer,Rest/binary>>) ->
    <<Signature:SLen/binary,Extradata/binary>>=Rest,
    {Signature,Extradata}.

unpacksig(HSig) when is_map(HSig) ->
    HSig;

unpacksig(BSig) when is_binary(BSig) ->
    {Signature,Hdr}=block:splitsig(BSig),
    #{ binextra => (Hdr),
       signature => (Signature),
       extra => block:unpack_sign_ed(Hdr)
     }.

binarize_settings([]) -> [];
binarize_settings([{TxID,#{ patch:=Patch,
                            signatures:=Sigs
                          }}|Rest]) ->
    [{TxID,settings:pack_patch(Patch,Sigs)}|binarize_settings(Rest)].


mkblock(#{ txs:=Txs, parent:=Parent, height:=H, bals:=Bals, settings:=Settings }=Req) ->
    BTxs=binarizetx(Txs),
    TxMT=gb_merkle_trees:from_list(BTxs),
    %TxHash=crypto:hash(sha256,BTxs),
    BalsBin=bals2bin(Bals),
    BalsMT=gb_merkle_trees:from_list(BalsBin),
    BSettings=binarize_settings(Settings),
    SettingsMT=gb_merkle_trees:from_list(BSettings),

    TxRoot=gb_merkle_trees:root_hash(TxMT),
    BalsRoot=gb_merkle_trees:root_hash(BalsMT),
    SettingsRoot=gb_merkle_trees:root_hash(SettingsMT),

    {BHeader,Hdr}=lists:foldl(
                    fun({_,undefined},{ABHhr,AHdr}) ->
                            {ABHhr,AHdr};
                       ({N,Root},{ABHhr,AHdr}) ->
                            {
                             <<ABHhr/binary,
                               Root/binary
                             >>,
                             maps:put(N,Root,AHdr)
                            }
                    end,

                    {
                     <<H:64/integer, %8
                       Parent/binary
                     >>,
                     #{ parent=>Parent, height=>H }
                    }, 
                    [{txroot,TxRoot},
                     {balroot,BalsRoot},
                     {setroot,SettingsRoot}
                    ]
                   ),

    %gb_merkle_trees:verify_merkle_proof(<<"aaa">>,<<1>>,T1).
    %gb_merkle_trees:merkle_proof (<<"aaa">>,T14) 
    %gb_merkle_trees:from_list([{<<"aaa">>,<<1>>},{<<"bbb">>,<<2>>},{<<"ccc">>,<<4>>}]).
    %gb_merkle_trees:verify_merkle_proof(<<"aaa">>,<<1>>,gb_merkle_trees:root_hash(T1),P1aaa)
    Block=#{header=>Hdr,
      hash=>crypto:hash(sha256,BHeader),
      txs=>Txs,
      bals=>Bals,
      settings=>Settings,
      sign=>[] },
    case maps:get(tx_proof, Req, []) of
        [] ->
            Block;
        List ->
            Proof=lists:map(
              fun(TxID) ->
                      {TxID,gb_merkle_trees:merkle_proof (TxID,TxMT)}
              end, List),
            maps:put(tx_proof,Proof,Block)
    end;

mkblock(Blk) ->
    case maps:is_key(settings,Blk) of
        false -> 
            mkblock(maps:put(settings, [], Blk));
        true ->
            io:format("s ~p~n",[maps:keys(Blk)]),
            throw(badmatch)
    end.

outward_mk(TxS,Block) -> 
    outward(TxS,Block,#{}).

outward([],Block,Acc) -> 
    maps:map(
      fun(_K,{Tx,Tp}) ->
              MiniBlock=maps:with([hash,header,sign],Block),
              MiniBlock#{ txs=>Tx, tx_proof=>Tp }
      end,
      Acc);

outward([{TxID,Chain}|Rest],#{txs:=Txs,tx_proof:=Proofs}=Block,Acc) ->
    {ChainTx,ChainTp}=maps:get(Chain,Acc,{[],[]}),
    Tx=proplists:get_value(TxID,Txs),
    Proof=proplists:get_value(TxID,Proofs),
    outward(Rest,
              Block,
              maps:put(Chain,
                       { [{TxID,Tx}|ChainTx], [{TxID,Proof}|ChainTp] } ,Acc)
             ).


binarizetx([]) ->
    [];

binarizetx([{TxID,Tx}|Rest]) ->
    BTx=tx:pack(Tx),
    %TxIDLen=size(TxID),
    %TxLen=size(BTx),
    %<<TxIDLen:8/integer,TxLen:16/integer,TxID/binary,BTx/binary,(binarizetx(Rest))/binary>>.
    [{TxID,BTx}|binarizetx(Rest)].

extract(<<>>) ->
    [];

extract(<<TxIDLen:8/integer,TxLen:16/integer,Body/binary>>) ->
    <<TxID:TxIDLen/binary,Tx:TxLen/binary,Rest/binary>> = Body,
    [{TxID,tx:unpack(Tx)}|extract(Rest)].

    
bals2bin(NewBal) ->
    lists:foldl(
      fun({{Addr,Cur},
           #{amount:=Amount,
             seq:=Seq,
             t:=T
            }
          },Acc) ->
              BAmount=trunc(Amount*1.0e9),
              [{<<Addr/binary,":",Cur/binary>>,
                <<BAmount:64/big,
                  Seq:64/big,
                  T:64/big>>}|Acc];
         ({Addr,
           #{chain:=NewChain}
          },Acc) ->
              [{<<Addr/binary>>,
                <<"pout", NewChain:64/big>>}|Acc]
      end, [],
      lists:keysort(1,maps:to_list(NewBal))
     ).

blkid(<<X:8/binary,_/binary>>) ->
    bin2hex:dbin2hex(X).

signhash(MsgHash, Timestamp, PrivKey) ->
    PubKey=secp256k1:secp256k1_ec_pubkey_create(PrivKey, true),
    BinExtra= pack_sign_ed([
             {pubkey,PubKey},
             {timestamp,Timestamp}
            ]),
    Msg=crypto:hash(sha256,<<BinExtra/binary,MsgHash/binary>>),
    Signature=secp256k1:secp256k1_ecdsa_sign(Msg, PrivKey, default, <<>>),
    <<255,(size(Signature)):8/integer,Signature/binary,BinExtra/binary>>.

sign(Blk, Timestamp, PrivKey) when is_map(Blk) ->
    Hash=maps:get(hash,Blk),
    Sign=signhash(Hash, Timestamp, PrivKey),
    Blk#{
      sign=>[Sign|maps:get(sign,Blk,[])]
     }.

sign(Blk, PrivKey) when is_map(Blk) ->
    Timestamp=os:system_time(millisecond),
    sign(Blk, Timestamp, PrivKey).

unpack_sign_ed(Bin) -> unpack_sign_ed(Bin,[]).
unpack_sign_ed(<<>>,Acc) -> lists:reverse(Acc);
unpack_sign_ed(<<Attr:8/integer,Len:8/integer,Bin/binary>>,Acc) ->
    <<Val:Len/binary,Rest/binary>>=Bin,
    unpack_sign_ed(Rest,[decode_edval(Attr,Val)|Acc]).


pack_sign_ed(List) ->
    lists:foldl( fun({K,V},Acc) ->
                         Val=encode_edval(K,V),
                         <<Acc/binary,Val/binary>>
                 end, <<>>, List).

decode_edval(1,<<Timestamp:64/big>>) -> {timestamp, Timestamp}; 
decode_edval(2,Bin) -> {pubkey, Bin}; 
decode_edval(255,Bin) -> {signature, Bin}; 
decode_edval(Key,BinVal) -> {Key, BinVal}.

encode_edval(timestamp, Integer) -> <<1,8,Integer:64/big>>;
encode_edval(pubkey, PK) -> <<2,(size(PK)):8/integer,PK/binary>>;
encode_edval(signature, PK) -> <<255,(size(PK)):8/integer,PK/binary>>;
encode_edval(_, _) -> <<>>.

test() ->
    test(block),
    test(outward).

test(block) ->
    Priv1Key= <<200,100,200,100,200,100,200,100,200,100,200,100,200,100,200,100,
                200,100,200,100,200,100,200,100,200,100,200,100,200,100,200,100>>,
    Priv2Key= <<200,300,200,100,200,100,200,100,200,100,200,100,200,100,200,100,
                200,300,200,100,200,100,200,100,200,100,200,100,200,100,200,100>>,
    Pub1=secp256k1:secp256k1_ec_pubkey_create(Priv1Key, true),
    Pub2=secp256k1:secp256k1_ec_pubkey_create(Priv2Key, true),
    RPatch=settings:mp(
            [
             #{t=>set,p=>[globals,patchsigs], v=>2},
             #{t=>set,p=>[chains], v=>[0]},
             #{t=>set,p=>[chain,0,minsig], v=>2},
             #{t=>set,p=>[keys,node1], v=>Pub1},
             #{t=>set,p=>[keys,node2], v=>Pub2},
             #{t=>set,p=>[nodechain], v=>#{node1=>0, node2=>0 } }
            ]),
    {SPatch,PatchSig1}= settings:sign_patch(RPatch, Priv1Key),
    {SPatch,PatchSig2}= settings:sign_patch(RPatch, Priv2Key),
    NewB=mkblock(#{ parent=><<0,0,0,0,0,0,0,0>>,
                    height=>0,
                    txs=>[],
                    bals=>#{},
                    settings=>[
                               {
                                bin2hex:dbin2hex(crypto:hash(sha256,SPatch)),
                                #{ patch=>SPatch,
                                   signatures=>[PatchSig1,PatchSig2]
                                 }
                               }
                              ],
                    sign=>[]
                  }
          ),
    Block=sign(sign(NewB,Priv1Key),Priv2Key),
    {Block,verify(Block),[Pub1,Pub2]};
 
test(outward) ->
    OWBlock= #{hash =>
               <<14,1,228,218,193,8,244,9,208,200,240,233,71,180,102,74,228,105,51,218,
                 183,50,35,187,180,162,124,160,31,202,79,181>>,
               header =>
               #{balroot =>
                 <<242,197,194,74,83,63,114,106,170,29,171,100,110,145,156,229,248,
                   193,67,96,252,37,74,167,55,118,102,39,230,116,92,37>>,
                 height => 2,
                 parent =>
                 <<228,113,37,150,139,59,113,4,159,188,72,2,209,228,10,113,234,19,
                   89,222,207,171,172,247,11,52,88,128,55,212,255,12>>,
                 txroot =>
                 <<152,24,115,240,203,150,198,199,248,230,189,172,102,188,31,1,165,
                   252,31,99,255,128,158,57,173,33,45,254,184,234,184,112>>},
               sign =>
               [<<255,70,48,68,2,32,9,192,225,152,36,213,20,185,130,242,124,4,152,56,
                  254,25,201,20,117,34,110,181,169,142,149,231,180,41,127,45,91,238,2,
                  32,58,8,8,179,135,155,118,195,65,189,150,50,16,110,155,152,100,240,
                  75,192,205,172,202,154,80,130,185,185,68,207,86,99,2,33,3,27,132,197,
                  86,123,18,100,64,153,93,62,213,170,186,5,101,215,30,24,52,96,72,25,
                  255,156,23,245,233,213,221,7,143,1,8,0,0,1,96,6,83,146,206>>],
               tx_proof =>
               [{<<"3crosschain">>,
                 {<<251,228,7,181,109,3,10,116,89,65,126,226,94,160,65,107,54,6,57,240,
                    190,94,81,94,110,18,100,225,240,244,193,225>>,
                  {<<116,218,137,92,172,222,193,162,49,219,55,17,33,216,114,180,76,1,
                     115,192,130,194,213,81,112,18,4,31,143,91,102,98>>,
                   <<22,213,23,196,75,239,21,127,57,214,89,128,188,225,152,85,12,
                     190,58,84,22,187,223,26,60,226,166,182,89,161,134,98>>}}}],
               txs =>
               [{<<"3crosschain">>,
                 #{amount => 9.0,cur => <<"FTT">>,extradata => <<>>,
                   from => <<"73Pa34g3R27Co7KzzNYT7t4UaPjQvpKA6esbuZxB">>,
                   outbound => 1,
                   public_key =>
                   <<"046A21F068BE92697268B60D96C4CA93052EC104E49E003AE2C404F916864372F4137039E85BC2CBA4935B6064B2B79150D99EDC10CA3C29142AA6B7F1E294B159">>,
                   seq => 3,
                   signature =>
                   <<"30440220455607D99DC5566660FCEB508FA980C954F74D4C344F4FCA0AE7709E7CBF4AA802202DC0B61A998AD98FDDB7AFD814F464EF0EFBC6D82CB15C2E0D912AE9D5C33498">>,
                   timestamp => 1511934628557211514,
                   to => <<"73f9e9yvV5BVRm9RUw3THVFon4rVqUMfAS1BNikC">>}}]},
    outward_verify(OWBlock).
