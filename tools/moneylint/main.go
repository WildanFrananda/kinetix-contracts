package main

import (
	"context"
	"strings"

	"buf.build/go/bufplugin/check"
	"buf.build/go/bufplugin/descriptor"
	"google.golang.org/protobuf/reflect/protoreflect"
)

const (
	ruleNoFloat  = "MONEY_NO_FLOATING_POINT"
	ruleUseMoney = "MONEY_USE_COMMON_TYPE"
)

var moneyNames = []string{
	"amount", "price", "fee", "total", "subtotal", "cost", "balance",
	"discount", "savings", "refund", "charge", "payout", "escrow", "value",
}

var notMoney = []string{
	"amount_minor",    // the integer half of Money itself
	"value_type",      // a discriminator, not a value
	"percentage",      // a rate, not an amount
	"percent",
	"rate",
	"quantity",
	"count",
}

func isMoneyName(name string) bool {
	lower := strings.ToLower(name)
	for _, exempt := range notMoney {
		if strings.Contains(lower, exempt) {
			return false
		}
	}
	for _, needle := range moneyNames {
		if strings.Contains(lower, needle) {
			return true
		}
	}
	return false
}

func checkNoFloat(
	_ context.Context,
	responseWriter check.ResponseWriter,
	_ check.Request,
	fileDescriptor descriptor.FileDescriptor,
) error {
	messages := fileDescriptor.ProtoreflectFileDescriptor().Messages()
	for i := 0; i < messages.Len(); i++ {
		walkMessage(responseWriter, messages.Get(i))
	}
	return nil
}

func walkMessage(
	responseWriter check.ResponseWriter,
	message protoreflect.MessageDescriptor,
) {
	fields := message.Fields()
	for i := 0; i < fields.Len(); i++ {
		field := fields.Get(i)
		kind := field.Kind()
		if kind != protoreflect.DoubleKind && kind != protoreflect.FloatKind {
			continue
		}
		if !isMoneyName(string(field.Name())) {
			continue
		}
		responseWriter.AddAnnotation(
			check.WithMessagef(
				"field %q is a %s. Money must be common.v1.Money{int64 amount_minor, string currency}: "+
					"a binary float cannot represent 0.1, so a total computed in one language "+
					"disagrees with the same total computed in another.",
				field.FullName(), kind.String(),
			),
			check.WithDescriptor(field),
		)
	}
	nested := message.Messages()
	for i := 0; i < nested.Len(); i++ {
		walkMessage(responseWriter, nested.Get(i))
	}
}

func checkUseCommonMoney(
	_ context.Context,
	responseWriter check.ResponseWriter,
	_ check.Request,
	fileDescriptor descriptor.FileDescriptor,
) error {
	fd := fileDescriptor.ProtoreflectFileDescriptor()
	// common/v1 defines Money; it cannot import itself.
	if strings.HasPrefix(string(fd.Package()), "common.v1") {
		return nil
	}
	messages := fd.Messages()
	for i := 0; i < messages.Len(); i++ {
		message := messages.Get(i)
		var hasAmount, hasCurrency bool
		fields := message.Fields()
		for j := 0; j < fields.Len(); j++ {
			name := strings.ToLower(string(fields.Get(j).Name()))
			if strings.Contains(name, "amount") || strings.Contains(name, "minor") {
				hasAmount = true
			}
			if strings.Contains(name, "currency") {
				hasCurrency = true
			}
		}
		if hasAmount && hasCurrency {
			responseWriter.AddAnnotation(
				check.WithMessagef(
					"message %q declares its own amount/currency pair. Import common.v1.Money "+
						"instead — a second definition of a money type is a second thing to keep "+
						"in step, and they do not stay in step.",
					message.FullName(),
				),
				check.WithDescriptor(message),
			)
		}
	}
	return nil
}

func main() {
	spec := &check.Spec{
		Rules: []*check.RuleSpec{
			{
				ID:      ruleNoFloat,
				Default: true,
				Purpose: "Checks that no money-bearing field is declared double or float.",
				Type:    check.RuleTypeLint,
				Handler: check.RuleHandlerFunc(
					func(ctx context.Context, w check.ResponseWriter, req check.Request) error {
						for _, fd := range req.FileDescriptors() {
							if err := checkNoFloat(ctx, w, req, fd); err != nil {
								return err
							}
						}
						return nil
					},
				),
			},
			{
				ID:      ruleUseMoney,
				Default: true,
				Purpose: "Checks that no message reinvents an amount/currency pair instead of common.v1.Money.",
				Type:    check.RuleTypeLint,
				Handler: check.RuleHandlerFunc(
					func(ctx context.Context, w check.ResponseWriter, req check.Request) error {
						for _, fd := range req.FileDescriptors() {
							if err := checkUseCommonMoney(ctx, w, req, fd); err != nil {
								return err
							}
						}
						return nil
					},
				),
			},
		},
	}
	check.Main(spec)
}
