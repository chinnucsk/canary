%% Copyright
-module(new_relic_api).
-author("jesse").

-include("canary.hrl").

%% API
-export([send_metrics/3]).

-define(RELIC_METRICS_POST_ENDPOINT, "https://platform-api.newrelic.com/platform/v1/metrics").
-define(RELIC_METRICS_POST_TRIES, 3).

%%
%%  Contains functions for posting metrics to NewRelic via their REST api.
%%


send_metrics(
    #relic_config{
            guid = Guid,
            entity_name = EntityName,
            license = LicenseKey,
            use_compression = UseCompression
    },
    HostName,
    Metrics)
    ->
    post_metric_report(
        Guid, EntityName, LicenseKey, UseCompression, HostName, Metrics
    ).


%% @doc Posts specified metrics to new relic's designated endpoint for receiving
%%  such reports.
post_metric_report(Guid, EntityName, LicenseKey, UseCompression, HostName, Metrics) ->
    BodyJson = {struct,
        [
            {agent,
                {struct,
                    [
                        {host, canary_utils:tobin(HostName)},
                        {pid, canary_utils:tobin(pid_to_list(self()))},
                        {version, ?RELIC_PLUGIN_VERSION}
                    ]
                }
            },
            {components,
                [
                    {struct,
                        [
                            {name, canary_utils:tobin(EntityName)},
                            {guid, canary_utils:tobin(Guid)},
                            {duration, 60},
                            {metrics, to_metrics_json(Metrics)}
                        ]
                    }
                ]
            }
        ]
    },

    post_metric_report__(
        metric_post_headers_and_body(
            LicenseKey, UseCompression,
            iolist_to_binary(canary_utils:tojson(BodyJson))
        ),
        0
    ).

post_metric_report__(_HeadersAndBody, Tries)
    when Tries >= ?RELIC_METRICS_POST_TRIES
    ->
    lager:error("New relic metrics post completely failed"),
    error;
post_metric_report__({Headers, Body}, Tries) ->
    case catch(
        httpc:request(post,
            {
                ?RELIC_METRICS_POST_ENDPOINT,
                [{"Accept", "application/json"}, {"Connection", "close"} | Headers],
                "application/json",
                Body
            },
            [{timeout, 3000}, {connect_timeout, 3000}],
            []
        )
    ) of
        {ok, {{_, 200, _}, _Headers, _ResponseBody}} ->
            ok;
        E ->
            lager:error("Error while posting new relic metrics ~p", [E]),
            post_metric_report__({Headers, Body}, Tries+1)
    end.


metric_post_headers_and_body(LicenseKey, false, Body) ->
    lager:error("New relic metric post report: ~p", [Body]),
    {[{"X-License-Key", LicenseKey}], Body};
metric_post_headers_and_body(LicenseKey, true, Body) ->
    lager:error("New relic metric post report: ~p", [Body]),
    {[{"X-License-Key", LicenseKey}, {"Content-Encoding", "gzip"}], zlib:gzip(Body)}.


%% @doc Converts a property list of metric names and values to correct json format
%%  expected in metrics post body
to_metrics_json(Metrics) ->
    to_metrics_json__(Metrics, {struct, []}).

to_metrics_json__([], Acc) ->
    Acc;
to_metrics_json__([Metric | RestMetrics], {struct, MetricsAcc}) ->
    to_metrics_json__(RestMetrics, {struct, [to_metric_json(Metric) | MetricsAcc]}).


to_metric_json({MetricName, MetricValue}) ->
    {to_metric_str(MetricName), to_metric_value_json(MetricValue)}.


to_metric_str(#canary_metric_name{category = Cat, label = Label, units = Units}) ->
    LabelStr = to_metric_label_str(Label),
    <<"Component/", Cat/binary, "/", LabelStr/binary, "[", Units/binary, "]">>.


to_metric_label_str(Label) when is_binary(Label) ->
    Label;
to_metric_label_str(Label) when is_list(Label) ->
    canary_utils:bjoin(Label, <<"/">>).


to_metric_value_json({counter, MetricValue}) when is_float(MetricValue); is_integer(MetricValue) ->
    MetricValue;
to_metric_value_json({gauge, MetricValue}) when is_float(MetricValue); is_integer(MetricValue) ->
    MetricValue;
to_metric_value_json(MetricSample = #histogram_sample{count = Count, total = Total, max = Max, min = Min}) ->
    attach_sum_of_squares(
        MetricSample,
        {struct,
            [
                {count, Count},
                {total, Total},
                {max, Max},
                {min, Min}
            ]
        }
    ).

attach_sum_of_squares(#histogram_sample{sum_of_squares = undefined}, MetricJson) ->
    MetricJson;
attach_sum_of_squares(#histogram_sample{sum_of_squares = SumOfSqrs}, {struct, MetricProps}) ->
    {struct, [{sum_of_squares, SumOfSqrs} | MetricProps]}.



