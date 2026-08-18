import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import getUsageAssets from '@salesforce/apex/OverageAmendmentController.getUsageAssets';
import getAmendmentContext from '@salesforce/apex/AmendmentQuoteController.getAmendmentContext';
import createAmendmentQuote from '@salesforce/apex/AmendmentQuoteController.createAmendmentQuote';
import patchQuoteAndPrice from '@salesforce/apex/AmendmentQuoteController.patchQuoteAndPrice';
import getQuoteCalculationStatus from '@salesforce/apex/AmendmentQuoteController.getQuoteCalculationStatus';
import fixQuoteAction from '@salesforce/apex/AmendmentQuoteController.fixQuoteAction';
import createOrderFromQuote from '@salesforce/apex/AmendmentQuoteController.createOrderFromQuote';
import activateOrder from '@salesforce/apex/AmendmentQuoteController.activateOrder';
import resetHasOverage from '@salesforce/apex/AmendmentQuoteController.resetHasOverage';

const DATE_FORMAT = { year: 'numeric', month: 'short', day: 'numeric' };

function formatDate(val) {
    if (!val) return null;
    return new Date(val).toLocaleDateString('en-US', DATE_FORMAT);
}

function toIsoDate(val) {
    if (!val) return null;
    return new Date(val + 'T00:00:00').toISOString().split('T')[0];
}

export default class OverageAmendmentModal extends NavigationMixin(LightningElement) {
    @api recordId;

    @track currentStep = 1;
    @track assets = [];
    @track selectedAssetId;
    @track selectedAsset;
    @track selectedResourceId;
    @track isLoading = true;
    @track isSubmitting = false;

    @track overageQty;
    @track billingPeriodStart;
    @track billingPeriodEnd;
    @track errorMessage;

    _sessionId;
    _amendmentContext;

    // ─── Session token via VF iframe ───────────────────────────────────────

    connectedCallback() {
        window.addEventListener('message', this._handleMessage.bind(this));
    }

    disconnectedCallback() {
        window.removeEventListener('message', this._handleMessage.bind(this));
    }

    _handleMessage(event) {
        if (event.data?.sessionId) {
            this._sessionId = event.data.sessionId;
        }
    }

    handleIframeLoad() {
        // iframe postMessage fires on load — handled by _handleMessage
    }

    // ─── Asset data ────────────────────────────────────────────────────────

    @wire(getUsageAssets, { accountId: '$recordId' })
    wiredAssets({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.assets = data.map(a => this.enrichAsset(a, false));
        } else if (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error loading assets',
                message: error.body?.message,
                variant: 'error'
            }));
        }
    }

    enrichAsset(a, isSelected) {
        const overageHistory = (a.overageHistory || []).map(oh => ({
            ...oh,
            periodStartFormatted: formatDate(oh.periodStart),
            periodEndFormatted: formatDate(oh.periodEnd),
            statusLabel: oh.status === 'Invoiced' ? 'Invoiced' : 'Not Invoiced',
            statusClass: oh.status === 'Invoiced' ? 'overage-status overage-status_invoiced' : 'overage-status overage-status_pending'
        }));
        return {
            ...a,
            usageResources: a.usageResources || [],
            overageHistory,
            hasSubscription: !!a.nextBillingDate,
            hasUsageResources: (a.usageResources || []).length > 0,
            hasOverageHistory: overageHistory.length > 0,
            nextBillingDateFormatted: formatDate(a.nextBillingDate),
            isSelected,
            cardClass: isSelected
                ? 'slds-box slds-m-bottom_small asset-card asset-card_selected'
                : 'slds-box slds-m-bottom_small asset-card'
        };
    }

    // ─── Getters ───────────────────────────────────────────────────────────

    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get stepLabel() { return this.currentStep === 1 ? 'Select Asset' : 'Confirm & Submit'; }
    get noAssets() { return !this.isLoading && this.assets.length === 0; }
    get isNextDisabled() { return !this.selectedAssetId; }

    get isSubmitDisabled() {
        return !this.selectedResourceId || !this.overageQty
            || !this.billingPeriodStart || !this.billingPeriodEnd
            || this.isSubmitting;
    }

    get submitLabel() {
        return this.isSubmitting ? 'Submitting...' : 'Submit Amendment';
    }

    get resourceOptions() {
        if (!this.selectedAsset) return [];
        return (this.selectedAsset.usageResources || []).map(ur => ({
            label: ur.resourceName + (ur.overageRate ? ' ($' + ur.overageRate + '/unit overage)' : ''),
            value: ur.usageResourceId
        }));
    }

    get amendmentStartDate() {
        if (!this.billingPeriodEnd) return null;
        const end = new Date(this.billingPeriodEnd + 'T00:00:00');
        const next = new Date(end.getFullYear(), end.getMonth() + 1, 1);
        return next.toLocaleDateString('en-US', DATE_FORMAT);
    }

    get amendmentStartDateIso() {
        if (!this.billingPeriodEnd) return null;
        const end = new Date(this.billingPeriodEnd + 'T00:00:00');
        const next = new Date(end.getFullYear(), end.getMonth() + 1, 1);
        return next.toISOString().split('T')[0];
    }

    // ─── Step 1 interactions ───────────────────────────────────────────────

    handleAssetSelect(event) {
        const newId = event.currentTarget.dataset.id;
        if (newId === this.selectedAssetId) return;
        const prevId = this.selectedAssetId;
        this.selectedAssetId = newId;

        this.assets = this.assets.map(a => {
            if (a.assetId !== newId && a.assetId !== prevId) return a;
            const selected = a.assetId === newId;
            return {
                ...a,
                isSelected: selected,
                cardClass: selected
                    ? 'slds-box slds-m-bottom_small asset-card asset-card_selected'
                    : 'slds-box slds-m-bottom_small asset-card'
            };
        });

        this.selectedAsset = this.assets.find(a => a.assetId === newId);
        this._amendmentContext = null;

        this.selectedResourceId = this.selectedAsset?.usageResources?.length === 1
            ? this.selectedAsset.usageResources[0].usageResourceId : null;
        this.overageQty = null;
        this.billingPeriodStart = null;
        this.billingPeriodEnd = null;
        this.errorMessage = null;
    }

    handleNext() {
        this.currentStep = 2;
        if (this.selectedAsset?.overageHistory?.length > 0) {
            const latest = this.selectedAsset.overageHistory[0];
            if (!this.billingPeriodStart && latest.periodStart) {
                this.billingPeriodStart = latest.periodStart.split('T')[0];
            }
            if (!this.billingPeriodEnd && latest.periodEnd) {
                this.billingPeriodEnd = latest.periodEnd.split('T')[0];
            }
            if (!this.overageQty && latest.overageQuantity > 0) {
                this.overageQty = latest.overageQuantity;
            }
            if (!this.selectedResourceId && latest.usageResourceId) {
                this.selectedResourceId = latest.usageResourceId;
            }
        }

        // Pre-fetch amendment context while user reviews Step 2
        getAmendmentContext({ assetId: this.selectedAsset.assetId })
            .then(ctx => { this._amendmentContext = ctx; })
            .catch(err => {
                this.errorMessage = 'Failed to load amendment context: ' + (err.body?.message || err.message);
            });
    }

    handleBack() {
        this.currentStep = 1;
        this.errorMessage = null;
    }

    handleResourceChange(event) { this.selectedResourceId = event.detail.value; }
    handleOverageQtyChange(event) { this.overageQty = parseInt(event.detail.value, 10); }
    handleBillingStartChange(event) { this.billingPeriodStart = event.detail.value; }
    handleBillingEndChange(event) { this.billingPeriodEnd = event.detail.value; this.errorMessage = null; }
    handleClose() { this.dispatchEvent(new CustomEvent('close')); }

    // ─── Submit ─────────────────────────────────────────────────────────────

    async handleSubmit() {
        this.errorMessage = null;
        if (!this.validateDates()) return;

        if (!this._sessionId) {
            this.errorMessage = 'Session token not ready. Please wait a moment and try again.';
            return;
        }
        if (!this._amendmentContext) {
            this.errorMessage = 'Amendment context still loading. Please try again.';
            return;
        }

        this.isSubmitting = true;
        const ctx = this._amendmentContext;

        const today = new Date().toISOString().split('T')[0];
        const amendPayload = {
            assetIds: [this.selectedAsset.assetId],
            amendmentStartDate: today + 'T00:00:00',
            outputRecordType: 'Quote',
            quantityChange: this.overageQty
        };
        if (ctx.contractId) amendPayload.contractId = ctx.contractId;

        console.log('Amend payload:', JSON.stringify(amendPayload, null, 2));
        try {
            const result = await createAmendmentQuote({
                sessionId: this._sessionId,
                amendPayloadJson: JSON.stringify(amendPayload)
            });
            const parsed = JSON.parse(result);
            console.log('Amend API response:', JSON.stringify(parsed, null, 2));

            // parsed.ok = true means HTTP 200; body contains the actual API response
            if (!parsed.ok) {
                this.errorMessage = 'Amendment failed: ' + (parsed.body || parsed.message);
                this.isSubmitting = false;
                return;
            }

            // Parse the nested API response body
            const apiBody = typeof parsed.body === 'string' ? JSON.parse(parsed.body) : parsed.body;
            console.log('API body:', JSON.stringify(apiBody, null, 2));

            if (!apiBody.success) {
                const errs = (apiBody.errors || []).map(e => e.errorMessage).join('; ');
                this.errorMessage = 'Amendment failed: ' + (errs || JSON.stringify(apiBody));
                this.isSubmitting = false;
                return;
            }

            const quoteId = apiBody.amendmentRecordId;

            // Brief wait for the amend API to fully commit records before patching
            await new Promise(resolve => setTimeout(resolve, 3000));

            // Step 2: Patch quote name + line StartDate + trigger pricing via Place Sales Transaction
            const quoteName = 'Overage Amendment - ' + this.selectedAsset.productName;
            const patchResult = await patchQuoteAndPrice({
                sessionId: this._sessionId,
                quoteId: quoteId,
                quoteName: quoteName,
                lineStartDate: this.amendmentStartDateIso
            });
            const patchParsed = JSON.parse(patchResult);
            console.log('Patch & price response:', JSON.stringify(patchParsed, null, 2));
            if (!patchParsed.ok) {
                this.errorMessage = 'Quote created but patch/pricing failed: ' + (patchParsed.body || patchParsed.message);
                this.isSubmitting = false;
                return;
            }

            // Step 3: Fix QuoteAction — PST PATCH leaves it as No Change, blocking pricing
            const fixResult = await fixQuoteAction({ quoteId: quoteId, assetId: this.selectedAsset.assetId });
            const fixParsed = JSON.parse(fixResult);
            console.log('Fix QuoteAction response:', JSON.stringify(fixParsed, null, 2));
            if (!fixParsed.ok) {
                this.errorMessage = 'Quote created but QuoteAction fix failed: ' + (fixParsed.message || '');
                this.isSubmitting = false;
                return;
            }

            // Step 5: Poll until quote pricing is complete before creating the order
            const MAX_POLLS = 20;
            for (let i = 0; i < MAX_POLLS; i++) {
                const calcStatus = await getQuoteCalculationStatus({ quoteId: quoteId });
                console.log('Quote CalculationStatus:', calcStatus);
                if (calcStatus === 'Completed' || calcStatus === 'CompletedWithPricing' || calcStatus === 'NotFound') break;
                if (i === MAX_POLLS - 1) {
                    this.errorMessage = 'Pricing did not complete in time (status: ' + calcStatus + '). Please reprice the quote manually and create the order from the quote record.';
                    this.isSubmitting = false;
                    return;
                }
                await new Promise(resolve => setTimeout(resolve, 2000));
            }

            // Step 6: Create order from the amendment quote via platform invocable action
            const orderResult = await createOrderFromQuote({ quoteId: quoteId });
            const orderParsed = JSON.parse(orderResult);
            console.log('Create order response:', JSON.stringify(orderParsed, null, 2));
            if (!orderParsed.ok) {
                this.errorMessage = 'Quote created but order creation failed: ' + (orderParsed.message || '');
                this.isSubmitting = false;
                return;
            }

            const orderId = orderParsed.orderId;
            if (!orderId) {
                this.errorMessage = 'Order created but could not retrieve order ID. Outputs: ' + (orderParsed.outputs || '');
                this.isSubmitting = false;
                return;
            }

            // Step 7: Activate the order
            const activateResult = await activateOrder({ orderId: orderId });
            const activateParsed = JSON.parse(activateResult);
            console.log('Activate response:', JSON.stringify(activateParsed, null, 2));
            if (!activateParsed.ok) {
                this.errorMessage = 'Order created but activation failed: ' + (activateParsed.body || activateParsed.message);
                this.isSubmitting = false;
                return;
            }

            const orderNumber = activateParsed.orderNumber;

            // Reset Has_Overage__c on the account
            await resetHasOverage({ accountId: this.recordId });

            this.dispatchEvent(new ShowToastEvent({
                title: 'Amendment Activated',
                message: quoteName + ' · Order ' + orderNumber + ' activated. Asset wallet replenished.',
                variant: 'success',
                mode: 'sticky'
            }));
            this.dispatchEvent(new CustomEvent('submit', { detail: { quoteId, orderId } }));

            // Navigate to the selected asset record
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.selectedAsset.assetId,
                    actionName: 'view'
                }
            });

        } catch (err) {
            this.errorMessage = 'Error: ' + (err.body?.message || err.message);
            this.isSubmitting = false;
        }
    }

    validateDates() {
        const start = new Date(this.billingPeriodStart);
        const end = new Date(this.billingPeriodEnd);
        if (end <= start) {
            this.errorMessage = 'Billing Period End must be after Billing Period Start.';
            return false;
        }
        return true;
    }
}
