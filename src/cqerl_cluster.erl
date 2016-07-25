-module (cqerl_cluster).

-export([
    init/1,
    terminate/2,
    code_change/3,

    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-export([
	start_link/0,

	get_any_client/1,
	get_any_client/0,

    add_nodes/1,
    add_nodes/2,
    add_nodes/3,
         remove_node/2
]).

-define (PRIMARY_CLUSTER, '$primary_cluster').

-record(cluster_table, {
          key :: cqerl_hash:key(),
          client_key :: cqerl_hash:key()
         }).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add_nodes(ClientKeys) ->
    gen_server:cast(?MODULE, {add_to_cluster, ?PRIMARY_CLUSTER, ClientKeys}).

add_nodes(ClientKeys, Opts) when is_list(ClientKeys) ->
    add_nodes(?PRIMARY_CLUSTER, ClientKeys, Opts);

add_nodes(Key, ClientKeys) when is_atom(Key) ->
    gen_server:cast(?MODULE, {add_to_cluster, Key, ClientKeys}).

add_nodes(Key, ClientKeys, Opts0) ->
	add_nodes(Key, lists:map(fun
		({Inet, Opts}) when is_list(Opts) ->
			{Inet, Opts ++ Opts0};
		(Inet) ->
			{Inet, Opts0}
	end, ClientKeys)).

remove_node(Key,NodePort) ->
    gen_server:cast(?MODULE, {removce_from_cluster, Key, NodePort}).

get_any_client(Key) ->
	case ets:lookup(cqerl_clusters, Key) of
		[] -> {error, cluster_not_configured};
		Nodes ->
            #cluster_table{client_key = {Node, Opts}} =
                           lists:nth(random:uniform(length(Nodes)), Nodes),
			cqerl_hash:get_client(Node, Opts)
	end.

get_any_client() ->
	get_any_client(?PRIMARY_CLUSTER).

init(_) ->
    ets:new(cqerl_clusters, [named_table, {read_concurrency, true}, protected, 
                             {keypos, #cluster_table.key}, bag]),
    {ok, undefined, 0}.

handle_cast({removce_from_cluster, ClusterKey, NodePort}, State) ->

    Tables = ets:lookup(cqerl_clusters, ClusterKey),
    L = [ A || {A,B,{NodePort1,Opts}} <- Tables , NodePort1 = NodePort ],
    io:format("~p ~p remove_from_cluster ~p ~n",[?MODULE,?LINE,L]),
    [ ets:delete_object(cqerl_clusters,A) || A <- L ],

    {noreply, State}.

handle_cast({add_to_cluster, ClusterKey, ClientKeys}, State) ->
	Tables = ets:lookup(cqerl_clusters, ClusterKey),
    GlobalOpts = application:get_all_env(cqerl),
    AlreadyStarted = sets:from_list(lists:map(fun
    	(#cluster_table{client_key=ClientKey}) -> ClientKey
    end, Tables)),
    NewClients = sets:subtract(sets:from_list(ClientKeys), AlreadyStarted),
    lists:map(fun (Key = {Node, Opts}) ->
        case cqerl_hash:get_client(Node, Opts) of
            {ok, _} ->
                ets:insert(cqerl_clusters, #cluster_table{key=ClusterKey, client_key=Key});
            {error, Reason} ->
                io:format(standard_error, "Error while starting client ~p for cluster ~p:~n~p", [Key, ClusterKey, Reason])
        end
    end, prepare_client_keys(sets:to_list(NewClients), GlobalOpts)),
    {noreply, State}.

handle_info(timeout, State) ->
	case application:get_env(cqerl, cassandra_clusters, undefined) of
    	undefined ->
    		case application:get_env(cqerl, cassandra_nodes, undefined) of
    			undefined -> ok;
    			ClientKeys when is_list(ClientKeys) ->
    				handle_cast({add_to_cluster, ?PRIMARY_CLUSTER, prepare_client_keys(ClientKeys)}, undefined)
    		end;

        Clusters when is_list(Clusters) ->
            lists:foreach(fun
                ({ClusterKey, {ClientKeys, Opts0}}) when is_list(ClientKeys) ->
                    handle_cast({add_to_cluster, ClusterKey, prepare_client_keys(ClientKeys, Opts0)}, undefined);

                ({ClusterKey, ClientKeys}) when is_list(ClientKeys) ->
                    handle_cast({add_to_cluster, ClusterKey, prepare_client_keys(ClientKeys)}, undefined)
            end, Clusters);

    	Clusters ->
    		maps:map(fun
    			(ClusterKey, {ClientKeys, Opts0}) when is_list(ClientKeys) ->
    				handle_cast({add_to_cluster, ClusterKey, prepare_client_keys(ClientKeys, Opts0)}, undefined);

				(ClusterKey, ClientKeys) when is_list(ClientKeys) ->
    				handle_cast({add_to_cluster, ClusterKey, prepare_client_keys(ClientKeys)}, undefined)
    		end, Clusters)
    end,
    {noreply, State};

handle_info(_Msg, State) ->
    {noreply, State}.

handle_call(_Msg, _From, State) -> 
    {reply, {error, unexpected_message}, State}.

code_change(_OldVsn, State, _Extra) -> 
    {ok, State}.

terminate(_Reason, _State) ->
	ok.

prepare_client_keys(ClientKeys) ->
    prepare_client_keys(ClientKeys, []).

prepare_client_keys(ClientKeys, SharedOpts) ->
    lists:map(fun
        ({Inet, Opts}) when is_list(Opts) ->
            {cqerl:prepare_node_info(Inet), Opts ++ SharedOpts};
        (Inet) ->
            {cqerl:prepare_node_info(Inet), SharedOpts}
    end, ClientKeys).
